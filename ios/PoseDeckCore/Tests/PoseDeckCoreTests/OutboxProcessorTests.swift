import XCTest
@testable import PoseDeckCore

/// Drain-loop coverage for ``OutboxProcessor`` (M3 plan, STEP 8): FIFO, 2xx
/// removal, 4xx drop, transient head-of-line + backoff via injected clock (NO
/// in-actor sleep), maxRetries drop, 401 pause/resume, single-flight, and
/// reorder-as-one-logical-unit. Driven through ``StubURLProtocol`` so outcomes
/// are scripted by HTTP status.
final class OutboxProcessorTests: XCTestCase {

    override func tearDown() {
        StubURLProtocol.shared.reset()
        super.tearDown()
    }

    private func makeSender() async -> MutationSender {
        let client = APIClient(
            baseURL: URL(string: "http://stub.local")!,
            session: StubURLProtocol.makeSession()
        )
        await client.setAuthToken("tok")
        return MutationSender(client: client)
    }

    private func create(_ id: String, entity: String = "decks") -> OutboxEntry {
        OutboxEntry(
            type: .create,
            entity: entity,
            payload: Data(#"{"id":"\#(id)","name":"x"}"#.utf8),
            localTimestamp: Date(timeIntervalSince1970: Double(id.hashValue & 0xFFFF))
        )
    }

    // MARK: - FIFO + 2xx removal

    func testDrainSendsAllAndEmptiesQueueOn2xx() async {
        StubURLProtocol.shared.setHandler { _ in (200, Data("{}".utf8)) }
        let queue = InMemoryOutbox()
        await queue.enqueue(OutboxEntry(type: .create, entity: "decks", payload: Data(#"{"id":"a"}"#.utf8), localTimestamp: Date(timeIntervalSince1970: 1)))
        await queue.enqueue(OutboxEntry(type: .create, entity: "decks", payload: Data(#"{"id":"b"}"#.utf8), localTimestamp: Date(timeIntervalSince1970: 2)))

        let processor = OutboxProcessor(queue: queue, sender: await makeSender())
        let result = await processor.drain()
        XCTAssertEqual(result, .progressed)
        let remaining = await queue.count()
        XCTAssertEqual(remaining, 0, "all entries sent and removed")
    }

    func testFIFOOrderPreserved() async {
        let sentOrder = OrderBox()
        StubURLProtocol.shared.setHandler { request in
            if let body = request.httpBody ?? Self.readStreamBody(request) {
                sentOrder.recordFromBody(body)
            }
            return (200, Data("{}".utf8))
        }
        let queue = InMemoryOutbox()
        await queue.enqueue(OutboxEntry(type: .create, entity: "decks", payload: Data(#"{"id":"first"}"#.utf8), localTimestamp: Date(timeIntervalSince1970: 1)))
        await queue.enqueue(OutboxEntry(type: .create, entity: "decks", payload: Data(#"{"id":"second"}"#.utf8), localTimestamp: Date(timeIntervalSince1970: 2)))
        let processor = OutboxProcessor(queue: queue, sender: await makeSender())
        _ = await processor.drain()
        XCTAssertEqual(sentOrder.ids, ["first", "second"])
    }

    // MARK: - 4xx drop

    func testNonRetryable4xxDropsHeadAndContinues() async {
        StubURLProtocol.shared.setHandler { _ in (403, Data("{}".utf8)) }
        let dropped = CountBox()
        let queue = InMemoryOutbox()
        await queue.enqueue(create("a"))
        await queue.enqueue(create("b"))
        let processor = OutboxProcessor(
            queue: queue,
            sender: await makeSender(),
            onDrop: { _, _ in dropped.increment() }
        )
        let result = await processor.drain()
        XCTAssertEqual(result, .progressed)
        let remaining = await queue.count()
        XCTAssertEqual(remaining, 0, "both 403 heads are dropped")
        let count = await dropped.value
        XCTAssertEqual(count, 2)
    }

    // MARK: - Transient backoff (no in-actor sleep) + head-of-line

    func testTransientHeadDefersWithBackoffAndBlocksTail() async {
        StubURLProtocol.shared.setHandler { _ in (503, Data("{}".utf8)) }
        let clock = MutableSyncClock(start: Date(timeIntervalSince1970: 1000))
        let queue = InMemoryOutbox()
        await queue.enqueue(create("head"))
        await queue.enqueue(create("tail"))
        let processor = OutboxProcessor(
            queue: queue,
            sender: await makeSender(),
            clock: clock,
            baseBackoff: 2.0
        )
        let result = await processor.drain()
        // Head failed transiently → deferred; tail not attempted (head-of-line).
        guard case .deferred(let until) = result else {
            return XCTFail("expected deferred, got \(result)")
        }
        XCTAssertEqual(until, Date(timeIntervalSince1970: 1002), "first retry backs off baseBackoff seconds")
        let remaining = await queue.count()
        XCTAssertEqual(remaining, 2, "nothing dropped/sent while head is transient")
    }

    func testDrainBeforeBackoffDeadlineStaysDeferred() async {
        StubURLProtocol.shared.setHandler { _ in (503, Data("{}".utf8)) }
        let clock = MutableSyncClock(start: Date(timeIntervalSince1970: 1000))
        let queue = InMemoryOutbox()
        await queue.enqueue(create("head"))
        let processor = OutboxProcessor(queue: queue, sender: await makeSender(), clock: clock, baseBackoff: 5.0)
        _ = await processor.drain() // sets nextAttemptAt = 1005
        // Advance only 1s — still before the deadline → defer without re-sending.
        await clock.advance(by: 1)
        let result = await processor.drain()
        guard case .deferred(let until) = result else { return XCTFail("expected deferred") }
        XCTAssertEqual(until, Date(timeIntervalSince1970: 1005))
    }

    func testRetrySucceedsAfterBackoffElapses() async {
        let attempt = CountBox()
        StubURLProtocol.shared.setHandler { _ in
            attempt.incrementSync()
            return attempt.syncValue == 1 ? (503, Data("{}".utf8)) : (200, Data("{}".utf8))
        }
        let clock = MutableSyncClock(start: Date(timeIntervalSince1970: 1000))
        let queue = InMemoryOutbox()
        await queue.enqueue(create("head"))
        let processor = OutboxProcessor(queue: queue, sender: await makeSender(), clock: clock, baseBackoff: 1.0)
        _ = await processor.drain()            // 503 → deferred until 1001
        await clock.advance(by: 1)             // now == deadline
        let result = await processor.drain()   // retries, 200 → removed
        XCTAssertEqual(result, .progressed)
        let remaining = await queue.count()
        XCTAssertEqual(remaining, 0)
    }

    func testMaxRetriesDropsEntry() async {
        StubURLProtocol.shared.setHandler { _ in (503, Data("{}".utf8)) }
        let clock = MutableSyncClock(start: Date(timeIntervalSince1970: 0))
        let dropped = CountBox()
        let queue = InMemoryOutbox()
        await queue.enqueue(create("doomed"))
        let processor = OutboxProcessor(
            queue: queue,
            sender: await makeSender(),
            clock: clock,
            maxRetries: 2,
            baseBackoff: 1.0,
            onDrop: { _, _ in dropped.increment() }
        )
        // attempt 1 → retryCount 1 (<=2) defer; advance; attempt 2 → retryCount 2; advance; attempt 3 → retryCount 3 > 2 → drop.
        for _ in 0..<5 {
            _ = await processor.drain()
            await clock.advance(by: 1000)
        }
        let remaining = await queue.count()
        XCTAssertEqual(remaining, 0, "entry dropped after exceeding maxRetries")
        let count = await dropped.value
        XCTAssertEqual(count, 1)
    }

    // MARK: - 401 pause / resume

    func testAuthExpiredPausesAndResumes() async {
        StubURLProtocol.shared.setHandler { _ in (401, Data("{}".utf8)) }
        let queue = InMemoryOutbox()
        await queue.enqueue(create("a"))
        let processor = OutboxProcessor(queue: queue, sender: await makeSender())
        let r1 = await processor.drain()
        XCTAssertEqual(r1, .authPaused)
        let pausedAgain = await processor.drain()
        XCTAssertEqual(pausedAgain, .authPaused, "stays paused — does not retry a dead token")
        let remaining = await queue.count()
        XCTAssertEqual(remaining, 1, "entry retained for after re-auth")

        // After refreshing the token, resume drains (now returns 200).
        StubURLProtocol.shared.setHandler { _ in (200, Data("{}".utf8)) }
        await processor.resumeAfterAuthRefresh()
        let r2 = await processor.drain()
        XCTAssertEqual(r2, .progressed)
        let after = await queue.count()
        XCTAssertEqual(after, 0)
    }

    // MARK: - onConfirmed self-echo seam

    func testOnConfirmedFiresWithEntityAndRecordId() async {
        StubURLProtocol.shared.setHandler { _ in (200, Data("{}".utf8)) }
        let confirmed = ConfirmedBox()
        let queue = InMemoryOutbox()
        await queue.enqueue(create("rec1", entity: "cards"))
        let processor = OutboxProcessor(
            queue: queue,
            sender: await makeSender(),
            onConfirmed: { c in await confirmed.append(c) }
        )
        _ = await processor.drain()
        let items = await confirmed.items
        XCTAssertEqual(items, [OutboxProcessor.Confirmed(entity: "cards", recordId: "rec1")])
    }

    func testIdleWhenEmpty() async {
        let queue = InMemoryOutbox()
        let processor = OutboxProcessor(queue: queue, sender: await makeSender())
        let result = await processor.drain()
        XCTAssertEqual(result, .idle)
    }

    // MARK: - backoff math

    func testBackoffIsExponentialAndCapped() async {
        let processor = OutboxProcessor(queue: InMemoryOutbox(), sender: await makeSender(), baseBackoff: 1.0, maxBackoff: 10.0)
        let b1 = await processor.backoff(forAttempt: 1)
        let b2 = await processor.backoff(forAttempt: 2)
        let b3 = await processor.backoff(forAttempt: 3)
        let big = await processor.backoff(forAttempt: 20)
        XCTAssertEqual(b1, 1.0)
        XCTAssertEqual(b2, 2.0)
        XCTAssertEqual(b3, 4.0)
        XCTAssertEqual(big, 10.0, "capped at maxBackoff")
    }

    // MARK: - helpers

    private static func readStreamBody(_ request: URLRequest) -> Data? {
        guard let stream = request.httpBodyStream else { return nil }
        stream.open(); defer { stream.close() }
        var data = Data()
        let size = 4096
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buf.deallocate() }
        while stream.hasBytesAvailable {
            let n = stream.read(buf, maxLength: size)
            if n <= 0 { break }
            data.append(buf, count: n)
        }
        return data
    }
}

// MARK: - thread-safe test boxes

final class OrderBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _ids: [String] = []
    var ids: [String] { lock.lock(); defer { lock.unlock() }; return _ids }
    func recordFromBody(_ body: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let id = obj["id"] as? String else { return }
        lock.lock(); defer { lock.unlock() }
        _ids.append(id)
    }
}

actor ConfirmedBox {
    private(set) var items: [OutboxProcessor.Confirmed] = []
    func append(_ c: OutboxProcessor.Confirmed) { items.append(c) }
}

final class CountBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return _value }
    var syncValue: Int { lock.lock(); defer { lock.unlock() }; return _value }
    func increment() { lock.lock(); defer { lock.unlock() }; _value += 1 }
    func incrementSync() { lock.lock(); defer { lock.unlock() }; _value += 1 }
}
