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
    let ownerId: String

    private(set) var state: LoadState = .idle
    private(set) var cards: [Card] = []
    /// First-image display URL per card id (nil = none / not yet resolved).
    private(set) var thumbnailURLs: [String: URL] = [:]

    var actionError: String?
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
        ownerId: String
    ) {
        self.deck = deck
        self.deckRepo = deckRepo
        self.cardRepo = cardRepo
        self.imageRepo = imageRepo
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

    func refresh() async {
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
        defer { reorderGate.finish() }

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
}
