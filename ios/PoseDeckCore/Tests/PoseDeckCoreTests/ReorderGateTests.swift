import XCTest
@testable import PoseDeckCore

/// Regression for SWIFT-1: concurrent reorders must be serialized. Overlapping
/// optimistic moves (a second `.onMove` firing while the first `reorderCards`
/// persist is still in flight) would stack a second optimistic reorder on an
/// unconfirmed one and launch a second interleaving PATCH loop. `ReorderGate`
/// models the serialization invariant: only one reorder may be in flight, and a
/// drop attempted while busy is a no-op (mirrors the web `reordering` guard).
final class ReorderGateTests: XCTestCase {

    func testStartsIdle() {
        let gate = ReorderGate()
        XCTAssertFalse(gate.isBusy)
    }

    func testBeginSucceedsWhenIdleAndMarksBusy() {
        var gate = ReorderGate()
        XCTAssertTrue(gate.begin(), "first reorder should be allowed to begin")
        XCTAssertTrue(gate.isBusy, "gate must be busy while a reorder is in flight")
    }

    /// The core SWIFT-1 invariant: a second `begin()` while the first is still
    /// in flight is rejected, so the overlapping drop is dropped rather than
    /// stacked onto the unconfirmed reorder.
    func testSecondBeginIsRejectedWhileInFlight() {
        var gate = ReorderGate()
        XCTAssertTrue(gate.begin())
        XCTAssertFalse(gate.begin(), "a second reorder must be blocked while one is in flight")
        XCTAssertTrue(gate.isBusy)
    }

    func testFinishReopensTheGate() {
        var gate = ReorderGate()
        XCTAssertTrue(gate.begin())
        gate.finish()
        XCTAssertFalse(gate.isBusy, "gate must reopen after the reorder settles")
        XCTAssertTrue(gate.begin(), "a fresh reorder should be allowed once the previous one finished")
    }

    /// Even if `finish()` runs on an already-open gate (e.g. a `defer` after an
    /// early-return path), it stays open and does not corrupt state.
    func testFinishIsIdempotentWhenNotBusy() {
        var gate = ReorderGate()
        gate.finish()
        XCTAssertFalse(gate.isBusy)
        XCTAssertTrue(gate.begin())
    }

    /// Simulates the bug scenario as a sequence: drop A begins (suspends at its
    /// await), drop B fires and is rejected (no second optimistic move / PATCH
    /// loop), A finishes, then a later drop C is allowed. The number of
    /// admitted reorders equals the number of non-overlapping drops, never the
    /// total number of drops.
    func testOverlappingDropsAdmitOnlyNonConcurrentReorders() {
        var gate = ReorderGate()
        var admitted = 0

        // Drop A: admitted, now in flight (suspended at await).
        if gate.begin() { admitted += 1 }
        // Drop B: fires before A settles -> rejected.
        if gate.begin() { admitted += 1 }
        // A settles.
        gate.finish()
        // Drop C: fires after A settled -> admitted.
        if gate.begin() { admitted += 1 }
        gate.finish()

        XCTAssertEqual(admitted, 2, "only the two non-overlapping drops should be admitted, not all three")
    }

    // MARK: - SWIFT-1: refresh coalescing while a reorder is in flight

    /// When idle, a refresh request must run immediately and leave nothing owed.
    func testRequestRefreshRunsImmediatelyWhenIdle() {
        var gate = ReorderGate()
        XCTAssertTrue(gate.requestRefresh(), "an idle gate should run the mirror re-query now")
        XCTAssertFalse(gate.pendingRefresh, "nothing should be owed when the refresh ran inline")
    }

    /// The core SWIFT-1 invariant: a mirror re-query (ticker / realtime bump)
    /// arriving while a reorder is in flight must NOT run — it would clobber the
    /// optimistic order with a partially-restriped ordering — and is recorded as
    /// owed instead.
    func testRequestRefreshIsDeferredWhileReorderInFlight() {
        var gate = ReorderGate()
        XCTAssertTrue(gate.begin())
        XCTAssertFalse(
            gate.requestRefresh(),
            "a re-query while a reorder is in flight must be skipped, not run"
        )
        XCTAssertTrue(gate.pendingRefresh, "the skipped re-query must be remembered as owed")
    }

    /// After the reorder settles, exactly one coalesced catch-up refresh is owed
    /// regardless of how many ticker bumps were skipped mid-flight, and draining
    /// it clears the flag so it does not run a second time.
    func testPendingRefreshCoalescesAndDrainsOnce() {
        var gate = ReorderGate()
        XCTAssertTrue(gate.begin())
        // Several mirror bumps land during the in-flight window.
        XCTAssertFalse(gate.requestRefresh())
        XCTAssertFalse(gate.requestRefresh())
        XCTAssertFalse(gate.requestRefresh())

        gate.finish()
        XCTAssertTrue(gate.takePendingRefresh(), "one catch-up refresh is owed after the reorder settles")
        XCTAssertFalse(gate.pendingRefresh, "draining must clear the owed flag")
        XCTAssertFalse(gate.takePendingRefresh(), "a second drain must not re-run the catch-up refresh")
    }

    /// A reorder with no concurrent mirror bump owes no catch-up refresh, so the
    /// gate's exit path does not perform a redundant re-read.
    func testNoPendingRefreshWhenNoBumpArrived() {
        var gate = ReorderGate()
        XCTAssertTrue(gate.begin())
        gate.finish()
        XCTAssertFalse(gate.takePendingRefresh(), "no re-query arrived, so none should be owed")
    }

    /// End-to-end sequence mirroring the view model: reorder begins, a ticker
    /// bump is skipped mid-flight, the reorder settles and reopens the gate, and
    /// the single coalesced refresh then runs through the now-idle gate.
    func testCatchUpRefreshRunsThroughReopenedGate() {
        var gate = ReorderGate()
        XCTAssertTrue(gate.begin())               // reorder starts (suspends at await)
        XCTAssertFalse(gate.requestRefresh())     // ticker bump arrives -> deferred
        gate.finish()                             // reorder settles, gate reopens
        XCTAssertTrue(gate.takePendingRefresh())  // catch-up is owed
        // The catch-up refresh now runs through the idle gate and is admitted.
        XCTAssertTrue(gate.requestRefresh(), "the coalesced refresh runs inline once the gate is idle")
    }
}
