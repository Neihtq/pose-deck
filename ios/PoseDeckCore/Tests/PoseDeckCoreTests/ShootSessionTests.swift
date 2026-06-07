import XCTest
@testable import PoseDeckCore

/// Exhaustive coverage for the pure ``ShootSession`` state machine (DESIGN.md
/// §4.2): initial order, done-advance + progress, skip-to-end + re-surface,
/// full LIFO undo reversal of done and skip, multi-level undo back to start,
/// single-card and all-skipped edges, the pinned cursor-position "Card N of M"
/// (`[FIX-M2a]`), and `isComplete`'s no-infinite-skip-trap semantics
/// (`[FIX-M2b]`).
final class ShootSessionTests: XCTestCase {

    private func session(_ ids: [String]) -> ShootSession { ShootSession(cardIds: ids) }

    // MARK: - Initial state

    func testInitialOrderAndCursor() {
        let s = session(["a", "b", "c"])
        XCTAssertEqual(s.workingOrder, ["a", "b", "c"])
        XCTAssertEqual(s.currentCardId, "a")
        XCTAssertEqual(s.progress.position, 1)
        XCTAssertEqual(s.progress.total, 3)
        XCTAssertFalse(s.isComplete)
        XCTAssertFalse(s.canUndo)
        XCTAssertEqual(s.skippedCount, 0)
    }

    // MARK: - markDone advance + progress

    func testMarkDoneAdvancesAndProgresses() {
        var s = session(["a", "b", "c"])
        s.markDone()
        XCTAssertEqual(s.currentCardId, "b")
        XCTAssertEqual(s.progress.position, 2, "second card")
        XCTAssertTrue(s.doneIds.contains("a"))
        s.markDone()
        XCTAssertEqual(s.currentCardId, "c")
        XCTAssertEqual(s.progress.position, 3)
        s.markDone()
        XCTAssertNil(s.currentCardId)
        XCTAssertTrue(s.isComplete)
        XCTAssertEqual(s.progress.position, 3, "position == total when complete")
    }

    // MARK: - skip moves to end + re-surfaces

    func testSkipMovesCardToEndAndSurfacesNext() {
        var s = session(["a", "b", "c"])
        s.skip()
        XCTAssertEqual(s.workingOrder, ["b", "c", "a"], "skipped card moves to the end")
        XCTAssertEqual(s.currentCardId, "b", "next card surfaces in the same slot")
        XCTAssertEqual(s.skippedCount, 1)
        XCTAssertFalse(s.isComplete, "a skipped card alone does not complete the session")
    }

    func testSkippedCardReSurfacesAndIsCompletable() {
        var s = session(["a", "b"])
        s.skip()                       // [b, a], a skipped, current b
        s.markDone()                   // done b → a re-surfaces as current
        XCTAssertEqual(s.currentCardId, "a", "the skipped card re-surfaces and is still shootable")
        // `[FIX-M2b]`: once acted-on (a was skipped, b done) the session reads
        // complete — the skipped card stays available but never traps the user.
        XCTAssertTrue(s.isComplete, "every card acted-on at least once")
        XCTAssertEqual(s.skippedCount, 1, "a is still skipped (not yet done)")
        s.markDone()                   // now finish a for real
        XCTAssertNil(s.currentCardId)
        XCTAssertTrue(s.isComplete)
        XCTAssertEqual(s.skippedCount, 0, "a is now done, no longer counted as skipped")
    }

    // MARK: - [FIX-M2a] pinned cursor-position N for skip-then-advance

    func testPinnedProgressForSkipThenAdvance() {
        var s = session(["a", "b", "c"])
        s.skip()                       // [b, c, a], current b, N stays 1
        XCTAssertEqual(s.progress.position, 1, "after a skip the new current card is still card 1")
        s.markDone()                   // done b → current c
        XCTAssertEqual(s.progress.position, 2, "skip-then-advance pins N = 2 of 3")
        XCTAssertEqual(s.progress.total, 3)
    }

    // MARK: - [FIX-M2b] isComplete no-infinite-skip-trap

    func testAllSkippedIsComplete() {
        var s = session(["a", "b"])
        s.skip()   // [b, a], a skipped
        s.skip()   // [a, b], b skipped too
        XCTAssertTrue(s.isComplete, "every card acted-on at least once → complete (no skip trap)")
        XCTAssertEqual(s.skippedCount, 2)
        // A current card is still available even when complete: the user may keep
        // shooting the skipped cards; the UI surfaces an end state but never locks.
        XCTAssertNotNil(s.currentCardId)
    }

    // MARK: - undo (done) full reversal

    func testUndoDoneRestoresCursorAndState() {
        var s = session(["a", "b", "c"])
        s.markDone()                   // done a → current b
        XCTAssertTrue(s.canUndo)
        s.undo()
        XCTAssertFalse(s.doneIds.contains("a"))
        XCTAssertEqual(s.currentCardId, "a", "cursor restored")
        XCTAssertEqual(s.progress.position, 1)
        XCTAssertFalse(s.canUndo)
    }

    // MARK: - undo (skip) full reversal

    func testUndoSkipRestoresOrderCursorAndSet() {
        var s = session(["a", "b", "c"])
        s.skip()                       // [b, c, a], a skipped
        s.undo()
        XCTAssertEqual(s.workingOrder, ["a", "b", "c"], "order fully restored")
        XCTAssertEqual(s.currentCardId, "a", "cursor restored")
        XCTAssertEqual(s.skippedCount, 0, "skip flag cleared")
        XCTAssertFalse(s.canUndo)
    }

    // MARK: - multi-level LIFO undo back to the very start

    func testMultiLevelUndoBackToStart() {
        var s = session(["a", "b", "c"])
        s.markDone()  // done a
        s.skip()      // skip b → [c, b, ...] wait: working becomes [c, b]? trace below
        s.markDone()  // done current
        // Unwind everything.
        s.undo()
        s.undo()
        s.undo()
        XCTAssertFalse(s.canUndo, "stack empty")
        XCTAssertEqual(s.workingOrder, ["a", "b", "c"], "order restored to initial")
        XCTAssertEqual(s.currentCardId, "a")
        XCTAssertTrue(s.doneIds.isEmpty)
        XCTAssertTrue(s.skippedActiveIds.isEmpty)
        XCTAssertEqual(s.progress.position, 1)
    }

    // MARK: - empty-stack undo is a no-op

    func testUndoOnEmptyStackIsNoOp() {
        var s = session(["a"])
        let before = s
        s.undo()
        XCTAssertEqual(s, before, "undo with nothing to reverse changes nothing")
    }

    // MARK: - single-card edges

    func testSingleCardDone() {
        var s = session(["only"])
        XCTAssertEqual(s.currentCardId, "only")
        XCTAssertEqual(s.progress.total, 1)
        s.markDone()
        XCTAssertTrue(s.isComplete)
        XCTAssertNil(s.currentCardId)
    }

    func testSingleCardSkipReSurfacesSameCard() {
        var s = session(["only"])
        s.skip()
        XCTAssertEqual(s.workingOrder, ["only"])
        XCTAssertEqual(s.currentCardId, "only", "the lone card re-surfaces")
        XCTAssertTrue(s.isComplete, "it was acted on, so not a trap")
    }

    func testEmptyDeckIsImmediatelyComplete() {
        let s = session([])
        XCTAssertNil(s.currentCardId)
        XCTAssertTrue(s.isComplete)
        XCTAssertEqual(s.progress.total, 0)
    }
}
