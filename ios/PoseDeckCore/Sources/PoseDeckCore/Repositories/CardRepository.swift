import Foundation

/// Data-access layer for the `cards` collection (ARCHITECTURE.md §3.3).
///
/// Wraps ``APIClient``'s generic CRUD. Cards live in a flat, ordered list within
/// a deck; ordering uses integer-gap `position` values (1000, 2000, …) so a
/// reorder restripes to clean gaps (ARCHITECTURE.md §3.3). Mirrors the web
/// `cardApi.ts` reference.
///
/// Conventions:
///  - Every mutation stamps `client_updated_at` with the current time
///    (last-write-wins prep — DESIGN.md §5 / ARCHITECTURE.md §4.3).
///  - Soft delete = set `deleted_at`; never hard-delete from the UI.
///  - List queries exclude soft-deleted cards (`deleted_at = ""`).
public struct CardRepository: Sendable {

    /// Integer gap between adjacent card positions.
    public static let positionGap = 1000

    /// Title cap enforced by the product UI (DESIGN.md §3 — Title <= 60).
    /// The DB field allows 200 as headroom; DESIGN wins for the client limit.
    public static let titleMaxLength = 60

    private let client: APIClient
    private let collection = "cards"

    /// Clock injected for testability; defaults to wall-clock `Date.init`.
    private let now: @Sendable () -> Date

    public init(client: APIClient, now: @escaping @Sendable () -> Date = Date.init) {
        self.client = client
        self.now = now
    }

    // MARK: - Editable fields

    /// Editable card fields a caller may set on create/update (DESIGN.md §3.3).
    public struct CardFields: Sendable, Equatable {
        public var title: String
        public var timeSlot: String?
        public var subjects: String?
        public var direction: String?
        public var notes: String?

        public init(
            title: String,
            timeSlot: String? = nil,
            subjects: String? = nil,
            direction: String? = nil,
            notes: String? = nil
        ) {
            self.title = title
            self.timeSlot = timeSlot
            self.subjects = subjects
            self.direction = direction
            self.notes = notes
        }

        /// Title clamped to the product cap (DESIGN.md §3, 60 chars).
        var clampedTitle: String { String(title.prefix(CardRepository.titleMaxLength)) }
    }

    // MARK: - Read

    /// List a deck's non-soft-deleted cards, ordered by `position`.
    public func listCards(deckId: String) async throws -> [Card] {
        let response = try await client.list(
            Card.self,
            collection: collection,
            perPage: 200,
            filter: "deck = \"\(deckId)\" && deleted_at = \"\"",
            sort: "position"
        )
        return response.items
    }

    // MARK: - Position math (pure, testable)

    /// Position for a new card appended to the end of the deck:
    /// `max(position) + positionGap`, or `positionGap` when the deck is empty.
    public static func nextPosition(after existing: [Card]) -> Int {
        guard let max = existing.map(\.position).max() else {
            return positionGap
        }
        return max + positionGap
    }

    /// Recompute integer-gap positions from an explicit ordering of card ids.
    /// Maps each id to `(index + 1) * positionGap`.
    public static func computeReorderedPositions(
        orderedIds: [String]
    ) -> [(id: String, position: Int)] {
        orderedIds.enumerated().map { index, id in
            (id: id, position: (index + 1) * positionGap)
        }
    }

    // MARK: - Write

    /// Create a card at the end of the deck.
    ///
    /// Reads the deck's current cards to compute the next integer-gap position,
    /// then creates the record. Optional fields default to `""` to match
    /// PocketBase's empty-string representation. Title is clamped to 60 chars.
    @discardableResult
    public func createCard(deckId: String, fields: CardFields) async throws -> Card {
        let existing = try await listCards(deckId: deckId)
        let position = Self.nextPosition(after: existing)
        let body = CreateCardBody(
            deck: deckId,
            position: position,
            title: fields.clampedTitle,
            time_slot: fields.timeSlot ?? "",
            subjects: fields.subjects ?? "",
            direction: fields.direction ?? "",
            notes: fields.notes ?? "",
            deleted_at: "",
            client_updated_at: PocketBaseDate.string(from: now())
        )
        return try await client.create(collection: collection, body: body)
    }

    /// Update editable fields on a card. Only provided keys are written; title,
    /// when provided, is clamped to 60 chars.
    @discardableResult
    public func updateCard(id: String, fields: PartialCardFields) async throws -> Card {
        let body = UpdateCardBody(
            title: fields.title.map { String($0.prefix(Self.titleMaxLength)) },
            time_slot: fields.timeSlot,
            subjects: fields.subjects,
            direction: fields.direction,
            notes: fields.notes,
            client_updated_at: PocketBaseDate.string(from: now())
        )
        return try await client.update(collection: collection, id: id, body: body)
    }

    /// Soft-delete a card (set `deleted_at`). Never hard-deletes.
    @discardableResult
    public func softDeleteCard(id: String) async throws -> Card {
        let stamp = PocketBaseDate.string(from: now())
        let body = SoftDeleteBody(deleted_at: stamp, client_updated_at: stamp)
        return try await client.update(collection: collection, id: id, body: body)
    }

    /// Reorder a deck's cards to match `orderedIds`, restriping positions to
    /// clean integer gaps (1000, 2000, …).
    ///
    /// `currentPositions` (optional) maps each card id to its position before
    /// the reorder so unmoved cards can be skipped — a reorder must not re-stamp
    /// `client_updated_at` on cards it did not move (which under last-write-wins
    /// could clobber a concurrent edit, ARCHITECTURE.md §4.3). Ids absent from
    /// the map are always written.
    public func reorderCards(
        deckId: String,
        orderedIds: [String],
        currentPositions: [String: Int]? = nil
    ) async throws {
        let stamp = PocketBaseDate.string(from: now())
        for (id, position) in Self.computeReorderedPositions(orderedIds: orderedIds) {
            if let current = currentPositions?[id], current == position {
                continue
            }
            let body = ReorderBody(position: position, client_updated_at: stamp)
            let _: Card = try await client.update(collection: collection, id: id, body: body)
        }
    }

    // MARK: - Encodable bodies

    /// Partial update fields; nil means "do not write this key".
    public struct PartialCardFields: Sendable, Equatable {
        public var title: String?
        public var timeSlot: String?
        public var subjects: String?
        public var direction: String?
        public var notes: String?

        public init(
            title: String? = nil,
            timeSlot: String? = nil,
            subjects: String? = nil,
            direction: String? = nil,
            notes: String? = nil
        ) {
            self.title = title
            self.timeSlot = timeSlot
            self.subjects = subjects
            self.direction = direction
            self.notes = notes
        }
    }

    struct CreateCardBody: Encodable, Sendable {
        let deck: String
        let position: Int
        let title: String
        let time_slot: String
        let subjects: String
        let direction: String
        let notes: String
        let deleted_at: String
        let client_updated_at: String
    }

    /// Update body. Optional keys are omitted from JSON when nil so PATCH only
    /// writes provided fields. `client_updated_at` is always present.
    struct UpdateCardBody: Encodable, Sendable {
        let title: String?
        let time_slot: String?
        let subjects: String?
        let direction: String?
        let notes: String?
        let client_updated_at: String

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: DynamicKey.self)
            if let title { try c.encode(title, forKey: "title") }
            if let time_slot { try c.encode(time_slot, forKey: "time_slot") }
            if let subjects { try c.encode(subjects, forKey: "subjects") }
            if let direction { try c.encode(direction, forKey: "direction") }
            if let notes { try c.encode(notes, forKey: "notes") }
            try c.encode(client_updated_at, forKey: "client_updated_at")
        }
    }

    struct SoftDeleteBody: Encodable, Sendable {
        let deleted_at: String
        let client_updated_at: String
    }

    struct ReorderBody: Encodable, Sendable {
        let position: Int
        let client_updated_at: String
    }
}

/// String coding key for sparse PATCH bodies.
struct DynamicKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

extension KeyedEncodingContainer where Key == DynamicKey {
    mutating func encode(_ value: String, forKey key: String) throws {
        try encode(value, forKey: DynamicKey(stringValue: key))
    }
}
