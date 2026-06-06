import Foundation

/// Mirrors the PocketBase `cards` collection (ARCHITECTURE.md §3.3).
public struct Card: Codable, Identifiable, Hashable, Sendable {
    /// PocketBase-generated record id.
    public var id: String
    /// Relation → `decks`. Required, cascade-delete.
    public var deck: String
    /// Ordering position; gaps allowed (integers like 1000, 2000, …).
    public var position: Int
    /// Card title. Required, max 200.
    public var title: String
    /// Optional time slot label.
    public var timeSlot: String?
    /// Optional subjects.
    public var subjects: String?
    /// Optional direction.
    public var direction: String?
    /// Optional notes, no length cap.
    public var notes: String?
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
        deck: String,
        position: Int,
        title: String,
        timeSlot: String? = nil,
        subjects: String? = nil,
        direction: String? = nil,
        notes: String? = nil,
        clientUpdatedAt: Date? = nil,
        created: Date? = nil,
        updated: Date? = nil,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.deck = deck
        self.position = position
        self.title = title
        self.timeSlot = timeSlot
        self.subjects = subjects
        self.direction = direction
        self.notes = notes
        self.clientUpdatedAt = clientUpdatedAt
        self.created = created
        self.updated = updated
        self.deletedAt = deletedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case deck
        case position
        case title
        case timeSlot = "time_slot"
        case subjects
        case direction
        case notes
        case clientUpdatedAt = "client_updated_at"
        case created
        case updated
        case deletedAt = "deleted_at"
    }
}
