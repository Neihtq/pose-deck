import Foundation

/// Data-access layer for the `card_completions` collection (ARCHITECTURE.md
/// §3.6).
///
/// Wraps ``APIClient``'s generic CRUD, mirroring ``DeckRepository`` /
/// ``CardRepository``. Completions are per-user shoot progress with a composite
/// unique constraint on `(card, user)`, so the record id is **client-minted and
/// deterministic** (``CardCompletion/deterministicId(card:user:)``) — this is the
/// fetch the app's backfill path calls to seed prior progress on a fresh launch
/// or a second device.
///
/// Conventions:
///  - Every write stamps `changed_at` (the LWW clock for completions — see
///    ``SyncRecord``).
///  - Writes use the deterministic id so a `.create` is idempotent across
///    devices and replays (`[FIX-C1]`).
public struct CardCompletionRepository: Sendable {

    private let client: APIClient
    private let collection = "card_completions"

    /// Clock injected for testability; defaults to wall-clock `Date.init`.
    private let now: @Sendable () -> Date

    public init(client: APIClient, now: @escaping @Sendable () -> Date = Date.init) {
        self.client = client
        self.now = now
    }

    // MARK: - Read

    /// List **every** completion for a user across all pages — the backfill
    /// baseline the sync coordinator merges into the local mirror on launch.
    ///
    /// Mirrors the web `getFullList`; a single-page `list` would silently drop a
    /// prolific user's progress beyond the first page.
    public func listCompletions(forUser userId: String) async throws -> [CardCompletion] {
        return try await client.listAll(
            CardCompletion.self,
            collection: collection,
            perPage: 200,
            filter: "user = \(PocketBaseFilter.quoted(userId))"
        )
    }

    // MARK: - Write (network variants, for parity / integration tests)

    /// Mark a `(card, user)` completion done over the network (deterministic id,
    /// idempotent create). For the app's offline path use
    /// ``OfflineWritePath/markCardCompletion(cardId:userId:state:)`` instead.
    @discardableResult
    public func markDone(cardId: String, userId: String) async throws -> CardCompletion {
        try await upsert(cardId: cardId, userId: userId, state: .done)
    }

    /// Mark a `(card, user)` completion skipped over the network.
    @discardableResult
    public func markSkipped(cardId: String, userId: String) async throws -> CardCompletion {
        try await upsert(cardId: cardId, userId: userId, state: .skipped)
    }

    /// Upsert by deterministic id: try a create, and on a composite-unique
    /// collision fall back to a state PATCH (the network mirror of `[FIX-C1]`).
    @discardableResult
    public func upsert(
        cardId: String,
        userId: String,
        state: CardCompletion.State
    ) async throws -> CardCompletion {
        let id = CardCompletion.deterministicId(card: cardId, user: userId)
        let stamp = now()
        let stampString = PocketBaseDate.string(from: stamp)
        let createBody = CreateBody(
            id: id,
            card: cardId,
            user: userId,
            state: state.rawValue,
            changed_at: stampString
        )
        do {
            let created: CardCompletion = try await client.create(collection: collection, body: createBody)
            return created
        } catch let APIClientError.httpError(status, body) where status == 400 && Self.isUniqueCollision(body) {
            // Row already exists for this (card, user) → PATCH the new state.
            let updateBody = UpdateBody(state: state.rawValue, changed_at: stampString)
            let updated: CardCompletion = try await client.update(collection: collection, id: id, body: updateBody)
            return updated
        }
    }

    /// PocketBase composite-unique collision on create (`validation_not_unique`).
    static func isUniqueCollision(_ body: Data) -> Bool {
        guard
            let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let data = root["data"] as? [String: Any]
        else {
            return false
        }
        // The collision surfaces on whichever unique field the server reports
        // (id or the composite); a `validation_not_unique` code anywhere means
        // "this completion already exists".
        for value in data.values {
            if let field = value as? [String: Any], field["code"] as? String == "validation_not_unique" {
                return true
            }
        }
        return false
    }

    // MARK: - Encodable bodies

    struct CreateBody: Encodable, Sendable {
        let id: String
        let card: String
        let user: String
        let state: String
        let changed_at: String
    }

    struct UpdateBody: Encodable, Sendable {
        let state: String
        let changed_at: String
    }
}
