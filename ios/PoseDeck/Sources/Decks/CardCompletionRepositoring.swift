import Foundation
import PoseDeckCore

/// App-side abstraction over the card-completion write/read path (mirrors
/// ``CardRepositoring``) so the shoot-mode view model can be driven by a fake in
/// previews/tests.
///
/// Completions are per-user shoot progress with a deterministic id keyed on
/// `(card, user)`. The read is deck-scoped via card ids (completions hold no deck
/// relation); writes flip the `(card, user)` state through the offline write path.
@MainActor
protocol CardCompletionRepositoring {
    /// All completions for the given user across the given cards (the shoot's
    /// deck-scoped card-id set). Used to hydrate prior progress on load.
    func completions(forCardIds cardIds: [String], userId: String) async throws -> [CardCompletion]
    @discardableResult
    func markDone(cardId: String, userId: String) async throws -> CardCompletion
    @discardableResult
    func markSkipped(cardId: String, userId: String) async throws -> CardCompletion
    /// Reset a `(card, user)` completion back to `pending` (the undo persist:
    /// STATE convergence only — never shoot order). `[FIX-M6]`
    @discardableResult
    func clearCompletion(cardId: String, userId: String) async throws -> CardCompletion
}

/// In-memory ``CardCompletionRepositoring`` for `#Preview`s and unit tests.
@MainActor
final class FakeCardCompletionRepository: CardCompletionRepositoring {
    /// Completions keyed by deterministic id.
    var byId: [String: CardCompletion]
    var error: Error?

    init(completions: [CardCompletion] = [], error: Error? = nil) {
        self.byId = Dictionary(uniqueKeysWithValues: completions.map { ($0.id, $0) })
        self.error = error
    }

    private func check() throws { if let error { throw error } }

    func completions(forCardIds cardIds: [String], userId: String) async throws -> [CardCompletion] {
        try check()
        let wanted = Set(cardIds)
        return byId.values.filter { wanted.contains($0.card) && $0.user == userId }
    }

    @discardableResult
    func markDone(cardId: String, userId: String) async throws -> CardCompletion {
        try check()
        return upsert(cardId: cardId, userId: userId, state: .done)
    }

    @discardableResult
    func markSkipped(cardId: String, userId: String) async throws -> CardCompletion {
        try check()
        return upsert(cardId: cardId, userId: userId, state: .skipped)
    }

    @discardableResult
    func clearCompletion(cardId: String, userId: String) async throws -> CardCompletion {
        try check()
        return upsert(cardId: cardId, userId: userId, state: .pending)
    }

    private func upsert(cardId: String, userId: String, state: CardCompletion.State) -> CardCompletion {
        let id = CardCompletion.deterministicId(card: cardId, user: userId)
        let completion = CardCompletion(id: id, card: cardId, user: userId, state: state, changedAt: Date())
        byId[id] = completion
        return completion
    }
}
