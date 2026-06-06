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
            await load()
        }
    }

    // MARK: - Deck actions

    func renameDeck(to name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
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
