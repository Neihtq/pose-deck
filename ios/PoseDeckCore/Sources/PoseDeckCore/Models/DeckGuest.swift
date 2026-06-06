import Foundation

/// Mirrors the PocketBase `deck_guests` collection (ARCHITECTURE.md §3.5).
///
/// Records which users have access to which decks. Composite unique on
/// `(deck, user)`.
public struct DeckGuest: Codable, Identifiable, Hashable, Sendable {
    /// PocketBase-generated record id.
    public var id: String
    /// Relation → `decks`.
    public var deck: String
    /// Relation → `users`.
    public var user: String
    /// When access was granted.
    public var grantedAt: Date?

    public init(
        id: String,
        deck: String,
        user: String,
        grantedAt: Date? = nil
    ) {
        self.id = id
        self.deck = deck
        self.user = user
        self.grantedAt = grantedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case deck
        case user
        case grantedAt = "granted_at"
    }
}
