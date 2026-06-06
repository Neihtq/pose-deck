import Foundation

/// Mirrors the PocketBase `card_images` collection (ARCHITECTURE.md §3.4).
///
/// The `file` field is a PocketBase file field: the API returns the stored
/// filename as a string, and the file is served via
/// `/api/files/<collection>/<recordId>/<filename>`.
public struct CardImage: Codable, Identifiable, Hashable, Sendable {
    /// PocketBase-generated record id.
    public var id: String
    /// Relation → `cards`. Required, cascade-delete.
    public var card: String
    /// Ordering position within a card.
    public var position: Int
    /// Stored filename for the single file on this record (max 1 file per record).
    public var file: String?
    /// Server-managed creation timestamp.
    public var created: Date?

    public init(
        id: String,
        card: String,
        position: Int,
        file: String? = nil,
        created: Date? = nil
    ) {
        self.id = id
        self.card = card
        self.position = position
        self.file = file
        self.created = created
    }

    enum CodingKeys: String, CodingKey {
        case id
        case card
        case position
        case file
        case created
    }
}
