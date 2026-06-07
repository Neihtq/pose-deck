import Foundation
import Observation
import PoseDeckCore

/// Drives ``DeckDetailView``: loads a deck's cards (ordered by position),
/// resolves each card's first-image thumbnail URL, and performs card-level
/// actions (reorder, inline soft-delete) plus deck-level actions (rename,
/// edit date, duplicate, soft-delete).
@MainActor
@Observable
final class DeckDetailViewModel {
    enum LoadState: Equatable { case idle, loading, loaded, failed(String) }

    /// The deck this detail screen renders. Kept mutable so header rename/date
    /// edits reflect immediately.
    private(set) var deck: Deck

    private let deckRepo: DeckRepositoring
    private let cardRepo: CardRepositoring
    private let imageRepo: CardImageReading
    /// Sharing (M5). Optional so previews/tests that don't exercise sharing can
    /// omit it; the Share affordance only appears for the owner anyway.
    private let guestRepo: DeckGuestRepositoring?
    let ownerId: String

    /// Whether the current user owns this deck. Only the owner may share, rename,
    /// duplicate, delete, or restore — a guest's deck-detail is read-only
    /// (`[FIX #3-iOS]`/owner-gating). Drives the UI's affordance visibility.
    var isOwner: Bool { deck.owner == ownerId }

    private(set) var state: LoadState = .idle
    private(set) var cards: [Card] = []
    /// First-image display URL per card id (nil = none / not yet resolved).
    private(set) var thumbnailURLs: [String: URL] = [:]

    /// Current guests of this deck (M5 sharing), oldest grant first. Re-read on
    /// the ticker bump so a realtime grant/revoke reflects live in the share UI.
    private(set) var guests: [DeckGuest] = []

    var actionError: String?
    /// Which modal sheet the deck-detail screen is presenting. Held on the
    /// `@Observable` model (not view `@State`) so it survives a parent re-render
    /// that rebuilds the pushed `DeckDetailView` (e.g. a deck-list ticker bump
    /// fired by an optimistic write would otherwise reset view `@State`). The
    /// share screen is a pushed destination, not a sheet — see ``DeckDetailView``.
    enum ActiveSheet: Int, Identifiable { case edit; var id: Int { rawValue } }
    var activeSheet: ActiveSheet?
    /// Set when the deck itself was soft-deleted from the header — the view pops.
    private(set) var didDelete = false

    /// Serializes optimistic reorders so a second `.onMove` (each fired in its
    /// own `Task` from the view) cannot stack on top of an unconfirmed reorder
    /// while the first is suspended at `await`. Mirrors the web `reordering`
    /// flag. `isReordering` is bound by the view to disable drag while busy.
    private var reorderGate = ReorderGate()
    var isReordering: Bool { reorderGate.isBusy }

    init(
        deck: Deck,
        deckRepo: DeckRepositoring,
        cardRepo: CardRepositoring,
        imageRepo: CardImageReading,
        guestRepo: DeckGuestRepositoring? = nil,
        ownerId: String
    ) {
        self.deck = deck
        self.deckRepo = deckRepo
        self.cardRepo = cardRepo
        self.imageRepo = imageRepo
        self.guestRepo = guestRepo
        self.ownerId = ownerId
    }

    var isEmpty: Bool { cards.isEmpty }

    /// Snapshot of current id→position used to skip unmoved cards on reorder.
    private var currentPositions: [String: Int] {
        Dictionary(uniqueKeysWithValues: cards.map { ($0.id, $0.position) })
    }

    func load() async {
        if case .loaded = state {} else { state = .loading }
        do {
            cards = try await cardRepo.listCards(deckId: deck.id)
            state = .loaded
            await loadThumbnails()
        } catch {
            state = .failed(DeckListViewModel.message(for: error))
        }
    }

    /// Re-read cards from the mirror after a realtime merge / outbox confirmation
    /// (the ticker bump) or a return from the editor.
    ///
    /// SWIFT-1 guard: while a reorder is being persisted, re-reading the mirror
    /// would overwrite the optimistic order with a partially-restriped ordering.
    /// `SwiftDataLocalStore` is an `actor` and `OfflineWritePath.reorderCards`
    /// upserts the moved cards one at a time across `await` boundaries, so a
    /// re-read landing in that gap can observe a neither-old-nor-new order and
    /// clobber the optimistic `cards` — defeating `ReorderGate`. So we skip the
    /// re-read while busy and remember that one is owed; `moveCards` runs the
    /// coalesced catch-up refresh once after the reorder settles.
    func refresh() async {
        guard reorderGate.requestRefresh() else { return }
        do {
            cards = try await cardRepo.listCards(deckId: deck.id)
            state = .loaded
            await loadThumbnails()
        } catch {
            actionError = DeckListViewModel.message(for: error)
        }
    }

    /// Resolve the first image (lowest position) for each card into a display
    /// URL. Best-effort: failures leave a card without a thumbnail rather than
    /// surfacing an error.
    private func loadThumbnails() async {
        var resolved: [String: URL] = [:]
        for card in cards {
            do {
                let images = try await imageRepo.listCardImages(cardId: card.id)
                if let first = images.first {
                    resolved[card.id] = try await imageRepo.fileURL(for: first)
                }
            } catch {
                continue
            }
        }
        thumbnailURLs = resolved
    }

    /// Re-mint a single card's thumbnail URL after its `AsyncImage` failed to
    /// load — most commonly an expired short-lived file `?token=` on a
    /// long-lived deck-detail session. Re-resolves the card's first image's
    /// display URL and adopts it only when it actually changed, to avoid an
    /// infinite reload loop on a genuine 404. Mirrors ``CardImagesViewModel``'s
    /// `refreshURL` and the web `DeckDetailPage` thumbnail `onError` handler.
    func refreshThumbnail(for card: Card) async {
        do {
            let images = try await imageRepo.listCardImages(cardId: card.id)
            guard let first = images.first else { return }
            let fresh = try await imageRepo.fileURL(for: first)
            if ThumbnailRefresh.shouldApply(fresh: fresh, current: thumbnailURLs[card.id]) {
                thumbnailURLs[card.id] = fresh
            }
        } catch {
            // Best-effort: a failed re-mint leaves the existing (broken)
            // thumbnail in place rather than surfacing an error.
        }
    }

    // MARK: - Card actions

    func deleteCard(at offsets: IndexSet) async {
        let targets = offsets.map { cards[$0] }
        do {
            for card in targets {
                _ = try await cardRepo.softDeleteCard(id: card.id)
            }
            await load()
        } catch {
            actionError = DeckListViewModel.message(for: error)
        }
    }

    /// Reorder cards locally then persist restriped positions (skipping cards
    /// whose position is unchanged so a reorder doesn't clobber concurrent edits).
    func moveCards(from source: IndexSet, to destination: Int) async {
        // Serialize: drop this move if a reorder is already being persisted.
        // Without this guard a second `.onMove` (its own Task) could run its
        // optimistic `cards.move` on the first move's server-unconfirmed array
        // and launch a second interleaving PATCH loop. Mirrors the web
        // early-return in `handleDragEnd`.
        guard reorderGate.begin() else { return }

        let before = currentPositions
        cards.move(fromOffsets: source, toOffset: destination)
        let orderedIds = cards.map(\.id)
        do {
            try await cardRepo.reorderCards(
                deckId: deck.id,
                orderedIds: orderedIds,
                currentPositions: before
            )
            await load()
        } catch {
            actionError = DeckListViewModel.message(for: error)
            // A mid-loop reorder failure leaves a partial server write (some cards
            // restriped, some not), so re-fetching via load() would surface a
            // neither-old-nor-new ordering. Restore the captured pre-drag order
            // locally instead, then refresh thumbnails without re-sorting from the
            // corrupted server state.
            cards = CardRepository.restoredOrder(of: cards, to: before)
            await loadThumbnails()
        }
        // Reopen the gate, then drain any mirror re-query that arrived (and was
        // skipped) while the reorder was in flight. Done explicitly rather than
        // in a `defer` so the catch-up `refresh()` runs *after* the gate is open
        // — otherwise `requestRefresh()` would just re-defer it forever (SWIFT-1).
        reorderGate.finish()
        if reorderGate.takePendingRefresh() {
            await refresh()
        }
    }

    // MARK: - Deck actions

    func renameDeck(to name: String) async {
        // Skip the write when the name is empty or unchanged: a no-op rename
        // would re-stamp `client_updated_at` and could clobber a concurrent edit
        // under last-write-wins (ARCHITECTURE.md §4.3). Mirrors the deck-LIST
        // path and the web `handleRename` early-return, and matches `editDate`'s
        // unchanged-value skip below.
        guard let trimmed = DeckEdits.renameTarget(proposed: name, current: deck.name) else { return }
        do {
            deck = try await deckRepo.renameDeck(id: deck.id, name: trimmed)
        } catch {
            actionError = DeckListViewModel.message(for: error)
        }
    }

    func editDate(to shootDate: Date?) async {
        if deck.shootDate == shootDate { return }
        do {
            deck = try await deckRepo.setShootDate(id: deck.id, shootDate: shootDate)
        } catch {
            actionError = DeckListViewModel.message(for: error)
        }
    }

    /// Apply both name and date from the edit sheet in one pass.
    func applyEdit(name: String, shootDate: Date?) async {
        await renameDeck(to: name)
        await editDate(to: shootDate)
    }

    @discardableResult
    func duplicateDeck() async -> Deck? {
        do {
            return try await deckRepo.duplicateDeck(id: deck.id, ownerId: ownerId)
        } catch {
            actionError = DeckListViewModel.message(for: error)
            return nil
        }
    }

    func softDeleteDeck() async {
        do {
            _ = try await deckRepo.softDeleteDeck(id: deck.id)
            didDelete = true
        } catch {
            actionError = DeckListViewModel.message(for: error)
        }
    }

    // MARK: - Sharing (M5)

    /// Re-read the deck's guests from the mirror (on open + each ticker bump).
    func loadGuests() async {
        guard let guestRepo else { return }
        do {
            guests = try await guestRepo.listGuests(deckId: deck.id)
        } catch {
            actionError = DeckListViewModel.message(for: error)
        }
    }

    /// Grant a guest by email. Guards self-share (`[FIX #4]`) and a duplicate of
    /// an already-granted user up front so the UI surfaces a clear message rather
    /// than relying solely on the server's composite-unique constraint.
    func grantGuest(email: String) async {
        guard let guestRepo else { return }
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            let resolved = try await guestRepo.grantGuest(deckId: deck.id, email: trimmed)
            // Pre-check duplicate locally (the server 400 is also handled as a
            // no-op, but a local guard gives an immediate, friendly message).
            if guests.contains(where: { $0.user == resolved.user && $0.id != resolved.id }) {
                actionError = "This deck is already shared with that user."
            }
            await loadGuests()
        } catch DeckGuestRepositoringError.userNotFound {
            actionError = "No user with that email."
        } catch {
            actionError = DeckListViewModel.message(for: error)
        }
    }

    func revokeGuest(_ guest: DeckGuest) async {
        guard let guestRepo else { return }
        do {
            try await guestRepo.revokeGuest(guest)
            await loadGuests()
        } catch {
            actionError = DeckListViewModel.message(for: error)
        }
    }
}
