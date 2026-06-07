import XCTest
@testable import PoseDeckCore

/// Regression for `swift-mirror-image-network-per-read`: `DeckDetailViewModel`
/// `.loadThumbnails()` used to resolve each card's thumbnail in a serialized
/// `for card in cards { await … }` loop — N back-to-back network round-trips per
/// refresh, with NO cancellation check, so a pass superseded by a newer trigger
/// (ticker bump / editor return) still ran every remaining round-trip. The web
/// reference fans these reads out with `Promise.all`.
///
/// The fan-out + cancellation contract is lifted into the pure `ThumbnailResolver`
/// (the network resolve itself lives in the app-target view model, compile-verified
/// only — the Simulator cannot boot in this env). These tests prove the resolver
/// (1) runs the per-card work CONCURRENTLY (not serialized) and (2) bails on
/// cancellation instead of resolving every id.
final class ThumbnailResolverTests: XCTestCase {

    private func url(_ s: String) -> URL { URL(string: s)! }

    /// Each id is resolved exactly once and the URLs are collected into the map.
    func testResolvesEachIdOnce() async {
        let counter = Counter()
        let result = await ThumbnailResolver.resolveAll(ids: ["a", "b", "c"]) { id in
            await counter.bump()
            return URL(string: "https://pb/\(id)")
        }
        XCTAssertEqual(result, [
            "a": url("https://pb/a"),
            "b": url("https://pb/b"),
            "c": url("https://pb/c"),
        ])
        let calls = await counter.value
        XCTAssertEqual(calls, 3, "resolver must call the per-card work once per id")
    }

    /// A per-card `nil` (no image / failed resolve) drops only that entry — the
    /// rest of the pass succeeds (best-effort, matching the old loop's `continue`).
    func testNilResultDropsOnlyThatEntry() async {
        let result = await ThumbnailResolver.resolveAll(ids: ["has", "none"]) { id in
            id == "none" ? nil : URL(string: "https://pb/\(id)")
        }
        XCTAssertEqual(result, ["has": url("https://pb/has")])
        XCTAssertNil(result["none"])
    }

    /// Empty input short-circuits to an empty map without scheduling work.
    func testEmptyIdsReturnsEmpty() async {
        let result = await ThumbnailResolver.resolveAll(ids: []) { _ in
            XCTFail("must not resolve anything for an empty id list")
            return nil
        }
        XCTAssertTrue(result.isEmpty)
    }

    /// THE FIX (concurrency): the per-card work runs CONCURRENTLY, not serialized.
    /// Each task signals arrival, then waits until ALL tasks have arrived before
    /// returning. A serialized loop would deadlock here (task 2 can't start until
    /// task 1 returns, but task 1 won't return until task 2 arrives). The
    /// concurrent fan-out lets all tasks arrive together, so this completes — and
    /// `concurrencyTimeout` proves it does not run them back-to-back.
    func testRunsConcurrentlyNotSerialized() async throws {
        let barrier = Barrier(expected: 4)
        let ids = ["a", "b", "c", "d"]
        let result = try await withTimeout(seconds: 5) {
            await ThumbnailResolver.resolveAll(ids: ids) { id in
                await barrier.arriveAndWait()
                return URL(string: "https://pb/\(id)")
            }
        }
        XCTAssertEqual(result.count, 4, "all ids resolve once every task overlaps")
    }

    /// THE FIX (cancellation): when the surrounding task is already cancelled,
    /// `resolveAll` returns empty without launching any per-card work — a pass the
    /// caller abandoned does not pay further network round-trips.
    func testCancelledBeforeStartResolvesNothing() async {
        let counter = Counter()
        let task = Task { () -> [String: URL] in
            await ThumbnailResolver.resolveAll(ids: ["a", "b", "c"]) { id in
                await counter.bump()
                return URL(string: "https://pb/\(id)")
            }
        }
        task.cancel()
        let result = await task.value
        XCTAssertTrue(result.isEmpty, "a pre-cancelled pass must resolve nothing")
        let calls = await counter.value
        XCTAssertEqual(calls, 0, "no per-card network work runs once the pass is cancelled")
    }

    // MARK: - Test helpers

    private actor Counter {
        private(set) var value = 0
        func bump() { value += 1 }
    }

    /// A reusable barrier: every caller blocks until `expected` callers have
    /// arrived, then all proceed. Used to force genuine concurrency.
    private actor Barrier {
        private let expected: Int
        private var arrived = 0
        private var waiters: [CheckedContinuation<Void, Never>] = []
        init(expected: Int) { self.expected = expected }
        func arriveAndWait() async {
            arrived += 1
            if arrived >= expected {
                for w in waiters { w.resume() }
                waiters.removeAll()
                return
            }
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    private struct TimeoutError: Error {}

    /// Run `work` but fail with a timeout if it does not finish in `seconds`
    /// (catches the deadlock a serialized implementation would cause).
    private func withTimeout<T: Sendable>(
        seconds: Double,
        _ work: @escaping @Sendable () async -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { await work() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TimeoutError()
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}
