import Foundation

/// The kind of mutation an outbox entry represents (ARCHITECTURE.md §4.1).
public enum OutboxMutationType: String, Codable, CaseIterable, Sendable {
    case create
    case update
    case delete
}

/// A single pending mutation awaiting upload to PocketBase.
///
/// Matches the `OutboxEntry` shape in ARCHITECTURE.md §4.1:
/// id, type (create/update/delete), entity, payload (JSON), idempotency_key (UUID),
/// local_timestamp, retry_count, last_error.
public struct OutboxEntry: Codable, Identifiable, Hashable, Sendable {
    /// Local identifier for this outbox row.
    public var id: UUID
    /// Mutation kind.
    public var type: OutboxMutationType
    /// Target collection name, e.g. `"decks"` (the "entity").
    public var entity: String
    /// Encoded mutation payload (PocketBase-shaped JSON record body).
    public var payload: Data
    /// Idempotency key so re-sent entries are de-duplicated by the server/queue.
    public var idempotencyKey: UUID
    /// Local clock timestamp when the mutation was enqueued.
    public var localTimestamp: Date
    /// Number of failed send attempts so far (drives exponential backoff in §4.2).
    public var retryCount: Int
    /// Last error string, if the most recent send attempt failed.
    public var lastError: String?

    public init(
        id: UUID = UUID(),
        type: OutboxMutationType,
        entity: String,
        payload: Data,
        idempotencyKey: UUID = UUID(),
        localTimestamp: Date = Date(),
        retryCount: Int = 0,
        lastError: String? = nil
    ) {
        self.id = id
        self.type = type
        self.entity = entity
        self.payload = payload
        self.idempotencyKey = idempotencyKey
        self.localTimestamp = localTimestamp
        self.retryCount = retryCount
        self.lastError = lastError
    }

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case entity
        case payload
        case idempotencyKey = "idempotency_key"
        case localTimestamp = "local_timestamp"
        case retryCount = "retry_count"
        case lastError = "last_error"
    }
}

/// Abstraction over the persistent outbox store.
///
/// The production iOS app backs this with SwiftData; tests and previews can use
/// the in-memory ``InMemoryOutbox``. Entries are processed FIFO by local
/// timestamp (ARCHITECTURE.md §4.2).
public protocol OutboxQueue: Sendable {
    /// Append an entry. Idempotent by `idempotencyKey`: enqueuing an entry whose
    /// key already exists is a no-op and returns `false`.
    @discardableResult
    func enqueue(_ entry: OutboxEntry) async -> Bool

    /// All pending entries in FIFO order (oldest `localTimestamp` first).
    func pending() async -> [OutboxEntry]

    /// Remove an entry once its mutation has been confirmed by the server (§4.2 step 5).
    func remove(id: UUID) async

    /// Persist an updated entry (e.g. after bumping `retryCount` / `lastError`).
    func update(_ entry: OutboxEntry) async
}

/// In-memory ``OutboxQueue`` for tests, previews, and the not-yet-online path.
///
/// Enforces idempotency-key de-duplication and FIFO ordering. Thread-safe via
/// actor isolation.
public actor InMemoryOutbox: OutboxQueue {
    private var entries: [OutboxEntry] = []
    private var seenKeys: Set<UUID> = []

    public init() {}

    @discardableResult
    public func enqueue(_ entry: OutboxEntry) async -> Bool {
        guard !seenKeys.contains(entry.idempotencyKey) else {
            return false
        }
        seenKeys.insert(entry.idempotencyKey)
        entries.append(entry)
        return true
    }

    public func pending() async -> [OutboxEntry] {
        entries.sorted { $0.localTimestamp < $1.localTimestamp }
    }

    public func remove(id: UUID) async {
        entries.removeAll { $0.id == id }
        // Note: idempotency keys are intentionally retained in `seenKeys` so a
        // confirmed-and-removed mutation cannot be re-enqueued with the same key.
    }

    public func update(_ entry: OutboxEntry) async {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else {
            return
        }
        entries[index] = entry
    }

    /// Test/debug helper: current entry count.
    public func count() async -> Int {
        entries.count
    }
}
