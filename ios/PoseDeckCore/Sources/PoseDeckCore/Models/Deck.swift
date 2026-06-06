import Foundation

/// Mirrors the PocketBase `decks` collection (ARCHITECTURE.md §3.2).
public struct Deck: Codable, Identifiable, Hashable, Sendable {
    /// PocketBase-generated record id.
    public var id: String
    /// Relation → `users`. Required.
    public var owner: String
    /// Deck name. Required, max 200.
    public var name: String
    /// Optional planned shoot date.
    public var shootDate: Date?
    /// Client clock at mutation time, used for last-write-wins conflict resolution.
    public var clientUpdatedAt: Date?
    /// Server-managed creation timestamp.
    public var created: Date?
    /// Server-managed last-update timestamp.
    public var updated: Date?
    /// Optional soft-delete timestamp.
    public var deletedAt: Date?

    public init(
        id: String,
        owner: String,
        name: String,
        shootDate: Date? = nil,
        clientUpdatedAt: Date? = nil,
        created: Date? = nil,
        updated: Date? = nil,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.owner = owner
        self.name = name
        self.shootDate = shootDate
        self.clientUpdatedAt = clientUpdatedAt
        self.created = created
        self.updated = updated
        self.deletedAt = deletedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case owner
        case name
        case shootDate = "shoot_date"
        case clientUpdatedAt = "client_updated_at"
        case created
        case updated
        case deletedAt = "deleted_at"
    }
}
