import XCTest
@testable import PoseDeckCore

/// Offline tests for the outbox queue skeleton: enqueue, FIFO ordering,
/// dedup-by-idempotency-key, retry bookkeeping, and removal.
final class OutboxTests: XCTestCase {

    private func makeEntry(
        type: OutboxMutationType = .create,
        entity: String = "decks",
        idempotencyKey: UUID = UUID(),
        timestamp: Date = Date()
    ) -> OutboxEntry {
        OutboxEntry(
            type: type,
            entity: entity,
            payload: Data("{}".utf8),
            idempotencyKey: idempotencyKey,
            localTimestamp: timestamp
        )
    }

    func testEnqueueAddsEntry() async {
        let outbox = InMemoryOutbox()
        let added = await outbox.enqueue(makeEntry())
        XCTAssertTrue(added)
        let count = await outbox.count()
        XCTAssertEqual(count, 1)
    }

    func testEnqueueDedupesByIdempotencyKey() async {
        let outbox = InMemoryOutbox()
        let key = UUID()
        let first = await outbox.enqueue(makeEntry(idempotencyKey: key))
        let second = await outbox.enqueue(makeEntry(idempotencyKey: key))
        XCTAssertTrue(first, "first enqueue with a fresh key should succeed")
        XCTAssertFalse(second, "second enqueue with the same key should be a no-op")
        let count = await outbox.count()
        XCTAssertEqual(count, 1, "duplicate idempotency key must not add a second entry")
    }

    func testPendingReturnsFIFOByLocalTimestamp() async {
        let outbox = InMemoryOutbox()
        let older = makeEntry(entity: "first", timestamp: Date(timeIntervalSince1970: 100))
        let newer = makeEntry(entity: "second", timestamp: Date(timeIntervalSince1970: 200))
        // Enqueue out of order to prove sorting, not insertion order, drives FIFO.
        await outbox.enqueue(newer)
        await outbox.enqueue(older)
        let pending = await outbox.pending()
        XCTAssertEqual(pending.map(\.entity), ["first", "second"])
    }

    func testRemoveDeletesEntryButKeepsKeyReserved() async {
        let outbox = InMemoryOutbox()
        let key = UUID()
        let entry = makeEntry(idempotencyKey: key)
        await outbox.enqueue(entry)
        await outbox.remove(id: entry.id)
        let countAfterRemove = await outbox.count()
        XCTAssertEqual(countAfterRemove, 0)

        // A confirmed-and-removed mutation must not be re-enqueued with the same key.
        let reAdded = await outbox.enqueue(makeEntry(idempotencyKey: key))
        XCTAssertFalse(reAdded, "previously confirmed idempotency key should remain reserved")
    }

    func testUpdatePersistsRetryBookkeeping() async {
        let outbox = InMemoryOutbox()
        var entry = makeEntry()
        await outbox.enqueue(entry)

        entry.retryCount += 1
        entry.lastError = "503 Service Unavailable"
        await outbox.update(entry)

        let pending = await outbox.pending()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.retryCount, 1)
        XCTAssertEqual(pending.first?.lastError, "503 Service Unavailable")
    }

    func testOutboxEntryRoundTripsWithSnakeCaseKeys() throws {
        let entry = OutboxEntry(
            type: .update,
            entity: "cards",
            payload: Data(#"{"title":"x"}"#.utf8),
            retryCount: 2,
            lastError: "boom"
        )
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(entry)
        let string = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(string.contains("\"idempotency_key\""))
        XCTAssertTrue(string.contains("\"local_timestamp\""))
        XCTAssertTrue(string.contains("\"retry_count\""))
        XCTAssertTrue(string.contains("\"last_error\""))

        let decoded = try decoder.decode(OutboxEntry.self, from: data)
        XCTAssertEqual(decoded, entry)
    }
}
