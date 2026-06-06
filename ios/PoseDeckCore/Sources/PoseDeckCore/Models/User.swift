import Foundation

/// Mirrors the PocketBase built-in `users` auth collection (ARCHITECTURE.md §3.1).
///
/// `password` is never returned by the PocketBase API (it is hashed and managed
/// server-side), so it is intentionally not modeled here.
public struct User: Codable, Identifiable, Hashable, Sendable {
    /// PocketBase-generated record id.
    public var id: String
    /// Unique login email.
    public var email: String
    /// Display name.
    public var name: String
    /// Server-managed creation timestamp.
    public var created: Date?
    /// Server-managed last-update timestamp.
    public var updated: Date?

    public init(
        id: String,
        email: String,
        name: String,
        created: Date? = nil,
        updated: Date? = nil
    ) {
        self.id = id
        self.email = email
        self.name = name
        self.created = created
        self.updated = updated
    }

    enum CodingKeys: String, CodingKey {
        case id
        case email
        case name
        case created
        case updated
    }
}
