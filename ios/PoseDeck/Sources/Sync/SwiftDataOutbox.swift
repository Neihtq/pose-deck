import Foundation
import SwiftData
import PoseDeckCore

/// SwiftData-backed ``OutboxQueue`` (M3 plan, STEP 10).
///
/// Persists pending mutations as `LocalOutboxEntry` rows so a queued offline
/// write survives relaunch, and drains them FIFO by `localTimestamp`.
///
/// Idempotency (invariant #1): an `enqueue` whose `idempotencyKey` is already
/// pending **or** was recently consumed is a no-op (`false`). The consumed-keys
/// set is **bounded and aged** — kept in `LocalConsumedKey` rows that are pruned
/// past `consumedKeyTTL` and a hard `consumedKeyCap` — so a long-lived process
/// never grows an unbounded in-memory `Set` (folds the unbounded-seenKeys
/// finding).
///
/// All SwiftData access runs on a dedicated background `ModelContext` created
/// from the shared container. The type is an `actor` so its context is touched
/// from exactly one isolation domain (SwiftData `ModelContext` is not
/// `Sendable`); `@unchecked Sendable` is unnecessary because the context never
/// escapes the actor.
actor SwiftDataOutbox: OutboxQueue {

    /// How long a consumed idempotency key is retained before it may be pruned.
    /// Comfortably longer than any realistic retry window so a lost-ack replay
    /// is still de-duplicated, but bounded so the table cannot grow forever.
    static let consumedKeyTTL: TimeInterval = 7 * 24 * 60 * 60 // 7 days
    /// Hard cap on retained consumed keys (oldest pruned first past this).
    static let consumedKeyCap = 5_000

    private let context: ModelContext
    private let now: @Sendable () -> Date

    init(container: ModelContainer, now: @escaping @Sendable () -> Date = { Date() }) {
        // A fresh context bound to the shared container, isolated to this actor.
        self.context = ModelContext(container)
        self.now = now
    }

    // MARK: - OutboxQueue

    @discardableResult
    func enqueue(_ entry: OutboxEntry) async -> Bool {
        if isKnownKey(entry.idempotencyKey) { return false }
        let row = LocalOutboxEntry(
            id: entry.id,
            typeRaw: entry.type.rawValue,
            entity: entry.entity,
            payload: entry.payload,
            idempotencyKey: entry.idempotencyKey,
            localTimestamp: entry.localTimestamp,
            retryCount: entry.retryCount,
            lastError: entry.lastError
        )
        context.insert(row)
        try? context.save()
        return true
    }

    func pending() async -> [OutboxEntry] {
        let descriptor = FetchDescriptor<LocalOutboxEntry>(
            sortBy: [SortDescriptor(\.localTimestamp, order: .forward)]
        )
        let rows = (try? context.fetch(descriptor)) ?? []
        return rows.compactMap(Self.toEntry)
    }

    func remove(id: UUID) async {
        let descriptor = FetchDescriptor<LocalOutboxEntry>(
            predicate: #Predicate { $0.id == id }
        )
        guard let row = try? context.fetch(descriptor).first else { return }
        // Record the consumed key (bounded/aged) BEFORE deleting the row so the
        // mutation cannot be re-enqueued under the same key after confirmation.
        recordConsumed(row.idempotencyKey)
        context.delete(row)
        try? context.save()
    }

    func update(_ entry: OutboxEntry) async {
        let id = entry.id
        let descriptor = FetchDescriptor<LocalOutboxEntry>(
            predicate: #Predicate { $0.id == id }
        )
        guard let row = try? context.fetch(descriptor).first else { return }
        row.retryCount = entry.retryCount
        row.lastError = entry.lastError
        try? context.save()
    }

    /// Test/debug helper: current pending count.
    func count() async -> Int {
        (try? context.fetchCount(FetchDescriptor<LocalOutboxEntry>())) ?? 0
    }

    // MARK: - Idempotency-key bookkeeping (bounded + aged)

    private func isKnownKey(_ key: UUID) -> Bool {
        let pendingDescriptor = FetchDescriptor<LocalOutboxEntry>(
            predicate: #Predicate { $0.idempotencyKey == key }
        )
        if let count = try? context.fetchCount(pendingDescriptor), count > 0 {
            return true
        }
        let consumedDescriptor = FetchDescriptor<LocalConsumedKey>(
            predicate: #Predicate { $0.key == key }
        )
        if let count = try? context.fetchCount(consumedDescriptor), count > 0 {
            return true
        }
        return false
    }

    private func recordConsumed(_ key: UUID) {
        pruneConsumedKeys()
        // Guard against a duplicate consumed row (unique constraint on `key`).
        let existing = FetchDescriptor<LocalConsumedKey>(
            predicate: #Predicate { $0.key == key }
        )
        if let count = try? context.fetchCount(existing), count > 0 { return }
        context.insert(LocalConsumedKey(key: key, consumedAt: now()))
    }

    /// Prune aged consumed keys (older than the TTL) and enforce the hard cap by
    /// deleting the oldest beyond it. Keeps the table bounded.
    private func pruneConsumedKeys() {
        let cutoff = now().addingTimeInterval(-Self.consumedKeyTTL)
        let agedDescriptor = FetchDescriptor<LocalConsumedKey>(
            predicate: #Predicate { $0.consumedAt < cutoff }
        )
        if let aged = try? context.fetch(agedDescriptor) {
            for row in aged { context.delete(row) }
        }

        // Enforce the cap: if still over, delete oldest-first.
        let allDescriptor = FetchDescriptor<LocalConsumedKey>(
            sortBy: [SortDescriptor(\.consumedAt, order: .forward)]
        )
        if let all = try? context.fetch(allDescriptor), all.count > Self.consumedKeyCap {
            for row in all.prefix(all.count - Self.consumedKeyCap) {
                context.delete(row)
            }
        }
    }

    // MARK: - Row ⇄ entry mapping

    private static func toEntry(_ row: LocalOutboxEntry) -> OutboxEntry? {
        guard let type = OutboxMutationType(rawValue: row.typeRaw) else { return nil }
        return OutboxEntry(
            id: row.id,
            type: type,
            entity: row.entity,
            payload: row.payload,
            idempotencyKey: row.idempotencyKey,
            localTimestamp: row.localTimestamp,
            retryCount: row.retryCount,
            lastError: row.lastError
        )
    }
}
