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
}
