import Foundation
import Observation
import PoseDeckCore

/// Drives ``DeckListView``: loads decks, applies search, groups them, and
/// performs deck-level mutations (create / rename / set date / duplicate /
/// soft-delete) against an injected ``DeckRepositoring``.
///
/// All grouping/search is delegated to ``PoseDeckCore/DeckGrouping`` (pure, with
/// `now` injected) so this view model stays a thin coordinator.
@MainActor
@Observable
final class DeckListViewModel {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    private let repo: DeckRepositoring
    /// Authenticated user id used as `owner` on create (required relation the
    /// server does not auto-populate).
    private let ownerId: String
    /// Injected clock for deterministic grouping in tests/previews.
    private let now: () -> Date

    private(set) var state: LoadState = .idle
    private(set) var decks: [Deck] = []

    /// Live search text bound to the search field.
    var searchText: String = ""

    /// Most recent transient error from a mutation, surfaced as an alert.
    var actionError: String?

    init(repo: DeckRepositoring, ownerId: String, now: @escaping () -> Date = Date.init) {
        self.repo = repo
        self.ownerId = ownerId
        self.now = now
    }

    /// The underlying repository, exposed so sibling screens (e.g. Trash) can be
    /// constructed with the same backing store.
    var repository: DeckRepositoring { repo }
    /// Authenticated user id (owner for created/duplicated decks).
    var owner: String { ownerId }

    /// Decks after applying the current search query (case-insensitive on name).
    var filteredDecks: [Deck] {
        DeckGrouping.searchDecks(decks, query: searchText)
    }

    /// Search-filtered decks grouped into Upcoming / Undated / Past.
    var grouped: DeckGrouping.GroupedDecks {
        DeckGrouping.groupDecks(filteredDecks, now: now())
    }

    var isEmpty: Bool { decks.isEmpty }

    func load() async {
        if case .loaded = state {} else { state = .loading }
        do {
            decks = try await repo.listDecks()
            state = .loaded
        } catch {
            state = .failed(Self.message(for: error))
        }
    }

    /// Pull-to-refresh: reload without flipping to the full-screen loading state.
    func refresh() async {
        do {
            decks = try await repo.listDecks()
            state = .loaded
        } catch {
            actionError = Self.message(for: error)
        }
    }

    @discardableResult
    func createDeck(name: String, shootDate: Date?) async -> Deck? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        do {
            let deck = try await repo.createDeck(name: trimmed, shootDate: shootDate, ownerId: ownerId)
            await load()
            return deck
        } catch {
            actionError = Self.message(for: error)
            return nil
        }
    }

    func rename(_ deck: Deck, to name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            _ = try await repo.renameDeck(id: deck.id, name: trimmed)
            await load()
        } catch {
            actionError = Self.message(for: error)
        }
    }

    /// Update a deck's shoot date. Skips the write when the date is unchanged.
    func editDate(_ deck: Deck, to shootDate: Date?) async {
        if deck.shootDate == shootDate { return }
        do {
            _ = try await repo.setShootDate(id: deck.id, shootDate: shootDate)
            await load()
        } catch {
            actionError = Self.message(for: error)
        }
    }

    /// Apply name + date edits from the editor sheet in one sequential pass
    /// (avoids two concurrent `load()`s racing) and reload once at the end.
    func applyEdit(_ deck: Deck, name: String, shootDate: Date?) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if !trimmed.isEmpty, trimmed != deck.name {
                _ = try await repo.renameDeck(id: deck.id, name: trimmed)
            }
            if deck.shootDate != shootDate {
                _ = try await repo.setShootDate(id: deck.id, shootDate: shootDate)
            }
            await load()
        } catch {
            actionError = Self.message(for: error)
        }
    }

    func duplicate(_ deck: Deck) async {
        do {
            _ = try await repo.duplicateDeck(id: deck.id, ownerId: ownerId)
            await load()
        } catch {
            actionError = Self.message(for: error)
        }
    }

    func softDelete(_ deck: Deck) async {
        do {
            _ = try await repo.softDeleteDeck(id: deck.id)
            await load()
        } catch {
            actionError = Self.message(for: error)
        }
    }

    static func message(for error: Error) -> String {
        if let e = error as? DeckRepositoryError {
            switch e {
            case .notFound: return "That deck no longer exists."
            }
        }
        return (error as? LocalizedError)?.errorDescription ?? "Something went wrong. Please try again."
    }
}
