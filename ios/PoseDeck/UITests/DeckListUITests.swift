import XCTest

/// M2 checklist — deck list: create, grouping, search, rename, duplicate,
/// delete → trash → restore.
///
/// Row interactions reveal the target row via search first (`revealDeck`) so it
/// is reliably on-screen — SwiftUI's lazy, grouped List only surfaces visible
/// cells to the accessibility tree.
final class DeckListUITests: PoseDeckUITestCase {

    /// Create an undated deck and a dated deck; confirm both appear and the
    /// grouping section headers ("Undated" / "Upcoming") are present.
    func testCreateAndGrouping() {
        launchAndSignIn()
        let undated = deckName("undated")
        let upcoming = deckName("upcoming")

        createDeck(named: undated, dated: false)
        createDeck(named: upcoming, dated: true) // shoot date = today → Upcoming

        XCTAssertTrue(app.staticTexts["Undated"].exists, "Undated section header missing")
        XCTAssertTrue(app.staticTexts["Upcoming"].exists, "Upcoming section header missing")

        trashDeck(undated)
        trashDeck(upcoming)
    }

    /// Search narrows the list to a matching deck and hides non-matches.
    func testSearchFilters() {
        launchAndSignIn()
        let keep = deckName("searchable-keep")
        let other = deckName("searchable-other")
        createDeck(named: keep)
        createDeck(named: other)

        // searchForDeck types the full name; assert match shows and the other
        // (different suffix) is filtered out.
        XCTAssertTrue(searchForDeck(keep).waitForExistence(timeout: Self.timeout), "Match should remain")
        XCTAssertFalse(deckRow(other).exists, "Non-match should be filtered out")

        clearSearch()
        trashDeck(keep)
        trashDeck(other)
    }

    /// Rename a deck via its context menu → the renamed row appears.
    func testRename() {
        launchAndSignIn()
        let original = deckName("rename-before")
        let renamed = deckName("rename-after")
        createDeck(named: original)

        revealDeck(original).press(forDuration: 1.0)
        let renameItem = app.buttons["Rename / Date"]
        XCTAssertTrue(renameItem.waitForExistence(timeout: Self.timeout), "Rename menu item missing")
        renameItem.tap()

        let nameField = waitFor("deckEditor.name", "Edit deck name field missing")
        // Replace the existing text: focus, select all, overtype.
        nameField.tap()
        nameField.press(forDuration: 1.0)
        if app.menuItems["Select All"].waitForExistence(timeout: 3) {
            app.menuItems["Select All"].tap()
        }
        nameField.typeText(renamed)
        waitFor("deckEditor.save").tap()

        XCTAssertTrue(
            searchForDeck(renamed).waitForExistence(timeout: Self.timeout),
            "Renamed deck missing"
        )
        clearSearch()

        trashDeck(renamed)
    }

    /// Duplicate a deck via swipe action → a "(copy)" row appears.
    func testDuplicate() {
        launchAndSignIn()
        let base = deckName("dup")
        createDeck(named: base)

        revealDeck(base).swipeLeft()
        let dup = app.buttons["Duplicate"]
        XCTAssertTrue(dup.waitForExistence(timeout: Self.timeout), "Duplicate swipe action missing")
        dup.tap()
        clearSearch()

        let copyName = "\(base) (copy)"
        XCTAssertTrue(
            searchForDeck(copyName).waitForExistence(timeout: Self.timeout),
            "Duplicated deck '\(copyName)' did not appear"
        )
        clearSearch()

        trashDeck(base)
        trashDeck(copyName)
    }

    /// Delete → the deck moves to Trash; Restore brings it back to the list.
    func testDeleteTrashRestore() {
        launchAndSignIn()
        let name = deckName("trash-restore")
        createDeck(named: name)

        // Delete via swipe + confirm.
        revealDeck(name).swipeLeft()
        app.buttons["Delete"].tap()
        let confirm = app.buttons["Move to Trash"]
        XCTAssertTrue(confirm.waitForExistence(timeout: Self.timeout), "Delete confirmation missing")
        confirm.tap()
        XCTAssertFalse(deckRow(name).waitForExistence(timeout: 5), "Deck should leave the active list")
        clearSearch()

        // Open Trash → restore.
        waitFor("decks.trash", "Trash button missing").tap()
        XCTAssertTrue(app.navigationBars["Trash"].waitForExistence(timeout: Self.timeout))
        let restore = waitFor("trash.restore.\(name)", "Restore button for trashed deck missing")
        restore.tap()
        app.buttons["Done"].tap()

        XCTAssertTrue(
            searchForDeck(name).waitForExistence(timeout: Self.timeout),
            "Restored deck did not return to the active list"
        )
        clearSearch()

        trashDeck(name)
    }
}
