import Foundation
import CryptoKit

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

    /// Derive the stable PocketBase record id for the `(card, user)` pair.
    ///
    /// A completion is uniquely keyed by `(card, user)` (composite unique in the
    /// schema, ARCHITECTURE.md §3.6), so the client can mint the *same* id for the
    /// same pair on every device and on every replay. That makes the offline
    /// `.create` idempotent without a server round-trip: a second device (or a
    /// lost-ack replay) computes the identical id, and PocketBase's composite
    /// unique constraint collapses the duplicate (``MutationSender`` then issues a
    /// state PATCH — see `[FIX-C1]`).
    ///
    /// The id is the SHA-256 of `"\(card)|\(user)"` mapped through
    /// ``IDGenerator``'s exact alphabet (`[a-z0-9]`) and length (15), so it is
    /// indistinguishable from a server-minted id and satisfies `^[a-z0-9]{15}$`.
    /// We map hash *bytes* into the alphabet rather than emitting hex so the id
    /// stays within PocketBase's record-id charset (hex would include no letters
    /// beyond `a–f` but, more importantly, the raw-hex length/shape would not
    /// match a real id).
    public static func deterministicId(card: String, user: String) -> String {
        let digest = SHA256.hash(data: Data("\(card)|\(user)".utf8))
        let alphabet = IDGenerator.alphabet
        var out = ""
        out.reserveCapacity(IDGenerator.idLength)
        for byte in digest.prefix(IDGenerator.idLength) {
            out.append(alphabet[Int(byte) % alphabet.count])
        }
        return out
    }
}
