import Foundation

/// Mirrors the PocketBase `card_completions` collection (ARCHITECTURE.md §3.6).
///
/// Per-user shoot progress. Composite unique on `(card, user)`.
public struct CardCompletion: Codable, Identifiable, Hashable, Sendable {
    /// Shoot progress state for a card, per user.
    public enum State: String, Codable, CaseIterable, Sendable {
        case done
        case skipped
        case pending
    }

    /// PocketBase-generated record id.
    public var id: String
    /// Relation → `cards`.
    public var card: String
    /// Relation → `users`.
    public var user: String
    /// Progress state.
    public var state: State
    /// When the state last changed.
    public var changedAt: Date?

    public init(
        id: String,
        card: String,
        user: String,
        state: State,
        changedAt: Date? = nil
    ) {
        self.id = id
        self.card = card
        self.user = user
        self.state = state
        self.changedAt = changedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case card
        case user
        case state
        case changedAt = "changed_at"
    }
}
