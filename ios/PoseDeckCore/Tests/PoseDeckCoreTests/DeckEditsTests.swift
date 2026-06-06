import XCTest
@testable import PoseDeckCore

/// Tests for `DeckEdits` rename-guard decision logic.
final class DeckEditsTests: XCTestCase {

    /// Regression (SPEC-1): a rename whose trimmed name equals the current name
    /// must be skipped so the deck-detail header does NOT issue a no-op
    /// `renameDeck` write that re-stamps `client_updated_at`. Previously
    /// `DeckDetailViewModel.renameDeck(to:)` guarded only on empty, diverging
    /// from the deck-list path and the web `handleRename` early-return and
    /// risking a last-write-wins clobber (ARCHITECTURE.md §4.3).
    func testRenameTargetReturnsNilWhenUnchanged() {
        XCTAssertNil(DeckEdits.renameTarget(proposed: "Beach Shoot", current: "Beach Shoot"))
    }

    /// Unchanged after trimming whitespace must also be treated as a no-op:
    /// trailing/leading spaces don't constitute a real rename.
    func testRenameTargetReturnsNilWhenUnchangedAfterTrim() {
        XCTAssertNil(DeckEdits.renameTarget(proposed: "  Beach Shoot  ", current: "Beach Shoot"))
    }

    /// An empty / whitespace-only proposed name is skipped (no rename to empty).
    func testRenameTargetReturnsNilWhenEmpty() {
        XCTAssertNil(DeckEdits.renameTarget(proposed: "", current: "Beach Shoot"))
        XCTAssertNil(DeckEdits.renameTarget(proposed: "   ", current: "Beach Shoot"))
    }

    /// A genuinely changed name is persisted, trimmed.
    func testRenameTargetReturnsTrimmedNameWhenChanged() {
        XCTAssertEqual(
            DeckEdits.renameTarget(proposed: "  Sunset Shoot ", current: "Beach Shoot"),
            "Sunset Shoot"
        )
    }
}
