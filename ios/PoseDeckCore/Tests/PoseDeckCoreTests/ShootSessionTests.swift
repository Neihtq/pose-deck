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

    // MARK: - Hydration (B5)

    /// A session hydrated from prior completion state seeds done/skipped sets,
    /// re-derives order from the supplied card ids, and skips over done cards.
    func testHydratedSessionSeedsStateAndSkipsDone() {
        let s = ShootSession(cardIds: ["a", "b", "c"], doneIds: ["a"], skippedActiveIds: ["b"])
        XCTAssertEqual(s.workingOrder, ["a", "b", "c"], "order is re-derived per-device, not synced")
        XCTAssertTrue(s.doneIds.contains("a"))
        XCTAssertEqual(s.currentCardId, "b", "cursor skips the already-done card")
        XCTAssertFalse(s.isComplete, "c is still neither done nor skipped")
        XCTAssertFalse(s.canUndo, "hydrated state seeds no undo history")
        XCTAssertEqual(s.skippedCount, 1)
    }

    /// Hydrated ids absent from the deck snapshot are ignored (a deleted card's
    /// stale completion can't seed phantom progress).
    func testHydratedSessionIgnoresAbsentIds() {
        let s = ShootSession(cardIds: ["a"], doneIds: ["ghost"], skippedActiveIds: [])
        XCTAssertTrue(s.doneIds.isEmpty)
        XCTAssertEqual(s.currentCardId, "a")
        XCTAssertFalse(s.isComplete)
    }

    // MARK: - [FIX-CORR-1] done card ahead of the cursor must not inflate N

    /// Regression for CORR-1: on a hydrated session the working order keeps done
    /// cards in position order (they are not relocated), so a done card can sit
    /// *ahead* of the cursor. Such a card has not been passed yet and must not
    /// count toward "Card N of M". The first card shown must read "Card 1 of M",
    /// never higher.
    func testProgressDoesNotCountDoneCardsAheadOfCursor() {
        // workingOrder = ["a","b","c"], "b" done but ahead of the cursor; current
        // is "a" at index 0. Before the fix this reported position 2 (0 + done
        // count 1 + 1).
        let s = ShootSession(cardIds: ["a", "b", "c"], doneIds: ["b"], skippedActiveIds: [])
        XCTAssertEqual(s.currentCardId, "a", "cursor sits on the first not-yet-done card")
        XCTAssertEqual(s.progress.position, 1, "the first card shown is Card 1, not inflated by the done card ahead of it")
        XCTAssertEqual(s.progress.total, 3)
    }

    /// Once the cursor advances past the done-ahead card, N counts it (it is now
    /// behind the cursor): position tracks cursor depth monotonically.
    func testProgressAdvancesPastDoneAheadCard() {
        var s = ShootSession(cardIds: ["a", "b", "c"], doneIds: ["b"], skippedActiveIds: [])
        XCTAssertEqual(s.progress.position, 1)
        s.markDone()                       // done "a" → cursor skips done "b" → current "c"
        XCTAssertEqual(s.currentCardId, "c", "cursor skips the already-done card ahead")
        XCTAssertEqual(s.progress.position, 3, "both 'a' (just done) and 'b' (done, now behind) are passed")
        XCTAssertEqual(s.progress.total, 3)
    }

    // MARK: - reset (re-shoot, item 3)

    /// `reset()` restores the original order even after a skip reordered the
    /// working order, clears all progress + undo history, and the result equals a
    /// fresh `init(cardIds:)`.
    func testResetRestoresOriginalOrderAndClearsProgress() {
        var s = session(["a", "b", "c"])
        s.skip()                           // ["b","c","a"], a skipped, current b
        s.markDone()                       // done b
        XCTAssertNotEqual(s.workingOrder, ["a", "b", "c"], "skip reordered the working order")
        XCTAssertTrue(s.canUndo)

        s.reset()

        XCTAssertEqual(s.workingOrder, ["a", "b", "c"], "working order restored to the original")
        XCTAssertEqual(s.originalOrder, ["a", "b", "c"], "original order preserved")
        XCTAssertEqual(s.currentCardId, "a", "cursor back at the first original card")
        XCTAssertFalse(s.isComplete)
        XCTAssertFalse(s.canUndo)
        XCTAssertTrue(s.doneIds.isEmpty)
        XCTAssertTrue(s.skippedActiveIds.isEmpty)
        XCTAssertEqual(s.progress.position, 1)
        XCTAssertEqual(s.progress.total, 3)
        XCTAssertEqual(s, ShootSession(cardIds: ["a", "b", "c"]), "a reset session equals a fresh one")
    }

    /// `originalOrder` comes from the constructor parameter, not from
    /// `workingOrder` (which `skip()` mutates), so resetting a session that began
    /// from a hydrated state still returns to the original card order.
    func testResetFromHydratedSessionReturnsToOriginal() {
        var s = ShootSession(cardIds: ["a", "b", "c"], doneIds: ["a"], skippedActiveIds: ["c"])
        XCTAssertEqual(s.originalOrder, ["a", "b", "c"])
        s.skip()                           // reorders working order
        s.reset()
        XCTAssertEqual(s.workingOrder, ["a", "b", "c"])
        XCTAssertEqual(s.currentCardId, "a")
        XCTAssertTrue(s.doneIds.isEmpty)
        XCTAssertTrue(s.skippedActiveIds.isEmpty)
        XCTAssertFalse(s.isComplete)
    }

    // MARK: - upcomingIds + reorderUpcoming (in-shoot overview, item 5)

    func testUpcomingIdsListsNotDoneFromCursor() {
        var s = session(["a", "b", "c", "d"])
        XCTAssertEqual(s.upcomingIds, ["a", "b", "c", "d"])
        s.markDone()                                   // a done, cursor at b
        XCTAssertEqual(s.upcomingIds, ["b", "c", "d"], "done card drops out of upcoming")
        XCTAssertEqual(s.upcomingIds.first, s.currentCardId)
    }

    func testUpcomingIdsEmptyWhenComplete() {
        var s = session(["a"])
        s.markDone()
        XCTAssertNil(s.currentCardId)
        XCTAssertEqual(s.upcomingIds, [])
    }

    func testReorderUpcomingPermutesWorkingOrder() {
        var s = session(["a", "b", "c", "d"])
        s.reorderUpcoming(["c", "a", "d", "b"])
        XCTAssertEqual(s.workingOrder, ["c", "a", "d", "b"])
        XCTAssertEqual(s.currentCardId, "c", "the new first upcoming card is current")
        XCTAssertEqual(s.progress.total, 4, "count is preserved")
    }

    func testReorderUpcomingOnlyTouchesSuffixAfterCursor() {
        var s = session(["a", "b", "c", "d"])
        s.markDone()                                   // a done, cursor at index 1 (b)
        s.reorderUpcoming(["d", "b", "c"])             // reorder the upcoming suffix
        XCTAssertEqual(s.workingOrder, ["a", "d", "b", "c"], "done prefix 'a' is pinned")
        XCTAssertEqual(s.currentCardId, "d")
        XCTAssertTrue(s.doneIds.contains("a"))
    }

    func testReorderUpcomingPinsDoneCardsAheadOfCursor() {
        // Hydrated session leaves a done card ahead of the cursor in position order.
        var s = ShootSession(cardIds: ["a", "b", "c", "d"], doneIds: ["c"], skippedActiveIds: [])
        XCTAssertEqual(s.currentCardId, "a")
        XCTAssertEqual(s.upcomingIds, ["a", "b", "d"], "done 'c' is excluded from upcoming")
        s.reorderUpcoming(["b", "d", "a"])
        // 'c' stays pinned at its original slot (index 2); not-done ids refill around it.
        XCTAssertEqual(s.workingOrder, ["b", "d", "c", "a"])
        XCTAssertTrue(s.doneIds.contains("c"))
    }

    func testReorderUpcomingRejectsNonPermutation() {
        var s = session(["a", "b", "c"])
        let before = s.workingOrder
        s.reorderUpcoming(["a", "b"])              // missing an id
        XCTAssertEqual(s.workingOrder, before, "dropped id → no-op")
        s.reorderUpcoming(["a", "b", "c", "x"])    // extra id
        XCTAssertEqual(s.workingOrder, before, "added id → no-op")
        s.reorderUpcoming(["a", "a", "b"])         // duplicate
        XCTAssertEqual(s.workingOrder, before, "duplicate id → no-op")
    }

    func testReorderUpcomingPreservesUndoability() {
        var s = session(["a", "b", "c"])
        s.markDone()                               // done a; undo frame pushed
        s.reorderUpcoming(["c", "b"])              // reorder the remaining upcoming
        XCTAssertEqual(s.currentCardId, "c")
        s.undo()                                   // reverse the done-a
        XCTAssertFalse(s.doneIds.contains("a"))
        XCTAssertEqual(s.currentCardId, "a", "undo restores the cursor to the un-done card")
    }
}
