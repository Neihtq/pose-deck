import XCTest
@testable import PoseDeckCore

/// Regression coverage for the mirror-change ticker's coalescing logic
/// (finding swift-3: the realtime-to-UI refresh bridge was dead code — never
/// instantiated, no view observed its `revision`, so a remote create/edit/delete
/// never appeared until a manual pull-to-refresh).
///
/// The app-target `MirrorChangeTicker` now (a) is owned by `SyncCoordinator` and
/// passed into `DeckListView` / `DeckDetailView`, which re-query in
/// `.task(id: ticker.revision)`, and (b) delegates its revision bookkeeping to
/// this pure `ChangeTickerCoalescer`. These tests pin the contract that drives
/// the re-query: a noted change produces exactly one observable bump, a burst
/// coalesces into one bump (no per-event stampede), and a flush with nothing
/// pending is a no-op (a stray debounce timer can't churn the UI).
final class ChangeTickerCoalescerTests: XCTestCase {

    /// A mirror change (e.g. a realtime merge writing the mirror) followed by a
    /// flush bumps `revision` — this is the signal a view's `.task(id:)` keys on
    /// to re-query. Without this the realtime path never reaches the UI.
    func testNotedChangeFlushesToOneRevisionBump() {
        var coalescer = ChangeTickerCoalescer()
        XCTAssertEqual(coalescer.revision, 0)
        XCTAssertFalse(coalescer.hasPendingChange)

        coalescer.noteChange()
        XCTAssertTrue(coalescer.hasPendingChange)

        let revision = coalescer.flush()
        XCTAssertEqual(revision, 1)
        XCTAssertEqual(coalescer.revision, 1)
        XCTAssertFalse(coalescer.hasPendingChange, "flush should clear the pending flag")
    }

    /// A burst of changes (a backfill or a flurry of realtime events) fires many
    /// `ModelContext.didSave` notifications; they must coalesce into a SINGLE
    /// bump after the quiet window, not one re-query per event.
    func testBurstOfChangesCoalescesIntoSingleBump() {
        var coalescer = ChangeTickerCoalescer()

        for _ in 0..<50 { coalescer.noteChange() }

        XCTAssertEqual(coalescer.flush(), 1, "a burst must coalesce into exactly one bump")
        XCTAssertEqual(coalescer.revision, 1)
    }

    /// A flush with nothing pending (e.g. a debounce timer that fires after the
    /// flag was already consumed) must NOT bump — otherwise observing views would
    /// re-query for no reason.
    func testFlushWithNothingPendingIsNoOp() {
        var coalescer = ChangeTickerCoalescer()

        XCTAssertEqual(coalescer.flush(), 0, "no pending change → no bump")
        XCTAssertEqual(coalescer.revision, 0)

        // After a real bump, a second flush with nothing newly pending also no-ops.
        coalescer.noteChange()
        XCTAssertEqual(coalescer.flush(), 1)
        XCTAssertEqual(coalescer.flush(), 1, "second flush with nothing pending must not bump again")
        XCTAssertEqual(coalescer.revision, 1)
    }

    /// Successive distinct change batches each produce their own bump, so a view
    /// keyed on `revision` re-queries once per batch (the steady-state realtime
    /// behaviour after the initial load).
    func testSuccessiveBatchesEachBumpOnce() {
        var coalescer = ChangeTickerCoalescer()

        coalescer.noteChange()
        XCTAssertEqual(coalescer.flush(), 1)

        coalescer.noteChange()
        coalescer.noteChange()
        XCTAssertEqual(coalescer.flush(), 2)

        coalescer.noteChange()
        XCTAssertEqual(coalescer.flush(), 3)
    }
}
