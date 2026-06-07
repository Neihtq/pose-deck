import XCTest
@testable import PoseDeckCore

/// Regression coverage for `[FIX-swift-4]`: the shoot view model's fire-and-forget
/// persist / prefetch work must be retained in cancellable handles, coalesced so
/// rapid input can't stack overlapping passes, and torn down when the screen goes
/// away — instead of leaking unstructured `Task {}` blocks that outlive the view.
@MainActor
final class ShootTaskSchedulerTests: XCTestCase {

    /// `cancelAll()` cancels in-flight persist work: a write blocked on a never-
    /// fulfilled gate observes cancellation and stops, rather than running to
    /// completion after teardown.
    func testCancelAllCancelsInFlightPersist() async {
        let scheduler = ShootTaskScheduler()
        let started = expectation(description: "persist started")
        let finished = expectation(description: "persist returned")
        var completedNormally = false

        scheduler.persist {
            started.fulfill()
            // Block until cancelled (no other waker exists).
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            completedNormally = !Task.isCancelled
            finished.fulfill()
        }

        await fulfillment(of: [started], timeout: 2.0)
        XCTAssertEqual(scheduler.pendingPersistCount, 1)

        scheduler.cancelAll()
        await fulfillment(of: [finished], timeout: 2.0)

        XCTAssertTrue(Task.isCancelled == false) // test task itself is fine
        XCTAssertFalse(completedNormally, "persist should observe cancellation, not finish normally")
        XCTAssertTrue(scheduler.isCancelled)
        XCTAssertEqual(scheduler.pendingPersistCount, 0)
    }

    /// A completed persist self-prunes from the bag so handles don't accumulate.
    func testPersistSelfPrunesOnCompletion() async {
        let scheduler = ShootTaskScheduler()
        let done = expectation(description: "persist done")
        scheduler.persist { done.fulfill() }
        await fulfillment(of: [done], timeout: 2.0)
        // Yield so the self-prune continuation (after work()) runs.
        for _ in 0..<10 where scheduler.pendingPersistCount != 0 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(scheduler.pendingPersistCount, 0)
    }

    /// `coalesce()` keeps a single prefetch task: a fresh request cancels the
    /// prior in-flight one so rapid swipes can't stack overlapping passes.
    func testCoalesceCancelsPreviousPrefetch() async {
        let scheduler = ShootTaskScheduler()
        let firstStarted = expectation(description: "first prefetch started")
        let firstCancelled = expectation(description: "first prefetch cancelled")
        let secondRan = expectation(description: "second prefetch ran")

        scheduler.coalesce {
            firstStarted.fulfill()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            firstCancelled.fulfill()
        }
        await fulfillment(of: [firstStarted], timeout: 2.0)

        // A second request must cancel the first and replace it.
        scheduler.coalesce { secondRan.fulfill() }

        await fulfillment(of: [firstCancelled, secondRan], timeout: 2.0)
    }

    /// After `cancelAll()`, further scheduling is refused (work never runs), so a
    /// late callback during teardown can't leak new tasks.
    func testSchedulingAfterCancelIsNoOp() async {
        let scheduler = ShootTaskScheduler()
        scheduler.cancelAll()

        var persistRan = false
        var prefetchRan = false
        scheduler.persist { persistRan = true }
        scheduler.coalesce { prefetchRan = true }

        // Give any (wrongly) scheduled task a chance to run.
        for _ in 0..<5 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 10_000_000)

        XCTAssertFalse(persistRan)
        XCTAssertFalse(prefetchRan)
        XCTAssertEqual(scheduler.pendingPersistCount, 0)
        XCTAssertFalse(scheduler.hasPendingPrefetch)
    }
}
