import XCTest

/// M2 checklist — deck detail + card editor: add cards, title counter / 60-cap,
/// field save, drag-to-reorder, swipe-to-delete inline.
final class CardUITests: PoseDeckUITestCase {

    /// Open a freshly created deck's detail screen. Reveals the row via search so
    /// it is on-screen, then taps it.
    private func openDeck(_ name: String) {
        createDeck(named: name)
        revealDeck(name).tap()
        XCTAssertTrue(
            app.navigationBars[name].waitForExistence(timeout: Self.timeout),
            "Deck detail for '\(name)' did not open"
        )
    }

    /// Add a card with all fields → it appears in the deck with its title.
    func testAddCardWithFields() {
        launchAndSignIn()
        let deck = deckName("cards-add")
        openDeck(deck)

        // Empty deck → the prominent empty-state Add Card button.
        waitFor("deck.addCard.empty", "Empty-state Add Card button missing").tap()

        let title = waitFor("cardEditor.title", "Card title field missing")
        title.tap(); title.typeText("Golden hour portrait")

        let timeSlot = element("cardEditor.timeSlot")
        timeSlot.tap(); timeSlot.typeText("16:30")
        let subjects = element("cardEditor.subjects")
        subjects.tap(); subjects.typeText("Bride & groom")
        let direction = element("cardEditor.direction")
        direction.tap(); direction.typeText("Backlit, look away")

        waitFor("cardEditor.save", "Card save button missing").tap()

        // Create returns straight to the deck (uploads staged images first, then
        // closes). The card should be present without a manual back-navigation.
        XCTAssertTrue(
            element("card.row.Golden hour portrait").waitForExistence(timeout: Self.timeout),
            "New card did not appear in the deck"
        )

        leaveDeckToList()
        trashDeck(deck)
    }

    /// Title counter reflects length and the 60-char cap disables save / shows a
    /// warning when exceeded.
    func testTitleCounterAndCap() {
        launchAndSignIn()
        let deck = deckName("cards-cap")
        openDeck(deck)
        waitFor("deck.addCard.empty").tap()

        let title = waitFor("cardEditor.title")
        title.tap(); title.typeText("Hello")

        let counter = element("cardEditor.titleCounter")
        XCTAssertTrue(counter.waitForExistence(timeout: 5))
        XCTAssertEqual(counter.label, "5/60", "Counter should reflect the 5-char title")

        // Type 61 characters total → over the 60 cap.
        title.typeText(String(repeating: "x", count: 56)) // 5 + 56 = 61
        XCTAssertTrue(
            app.staticTexts["Title must be 60 characters or fewer."].waitForExistence(timeout: 5),
            "Over-cap warning did not appear"
        )
        // Use a precisely-typed button so isEnabled reflects the control.
        XCTAssertFalse(
            button("cardEditor.save").isEnabled,
            "Save should be disabled when the title exceeds 60 chars"
        )

        // Discard by navigating back (no card was created).
        navigateBack()
        leaveDeckToList()
        trashDeck(deck)
    }

    /// Swipe-to-delete a card inline from the deck detail (no need to open it).
    func testSwipeDeleteCardInline() {
        launchAndSignIn()
        let deck = deckName("cards-swipe")
        openDeck(deck)
        addCard(titled: "Throwaway shot")

        let row = element("card.row.Throwaway shot")
        XCTAssertTrue(row.waitForExistence(timeout: Self.timeout))
        row.swipeLeft()
        let delete = app.buttons["Delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: Self.timeout), "Swipe Delete action missing")
        delete.tap()

        XCTAssertFalse(
            element("card.row.Throwaway shot").waitForExistence(timeout: 5),
            "Card should be removed after inline swipe-delete"
        )

        leaveDeckToList()
        trashDeck(deck)
    }

    /// Drag-to-reorder persists: reorder two cards in Edit mode, leave and
    /// re-open the deck, and confirm the new order survives a reload.
    func testReorderPersists() {
        launchAndSignIn()
        let deck = deckName("cards-reorder")
        openDeck(deck)
        addCard(titled: "Card Alpha")
        addCard(titled: "Card Bravo")

        // Enter edit mode.
        waitFor("deck.editButton", "Edit button missing").tap()

        let alpha = element("card.row.Card Alpha")
        let bravo = element("card.row.Card Bravo")
        XCTAssertTrue(alpha.waitForExistence(timeout: Self.timeout))
        XCTAssertTrue(bravo.waitForExistence(timeout: Self.timeout))

        // The reorder grabber sits at the trailing edge of each row (no separate
        // AX element). Press-and-hold to lift Bravo, drag up to just above
        // Alpha, then HOLD before releasing so SwiftUI registers the drop — the
        // plain press+drag is too fast and lands back in place.
        let bravoGrab = bravo.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5))
        let alphaTop = alpha.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.05))
        bravoGrab.press(
            forDuration: 1.0,
            thenDragTo: alphaTop,
            withVelocity: .slow,
            thenHoldForDuration: 0.8
        )

        // Leave edit mode.
        waitFor("deck.editButton").tap()

        // Reload by leaving and re-entering the deck.
        leaveDeckToList()
        revealDeck(deck).tap()
        XCTAssertTrue(app.navigationBars[deck].waitForExistence(timeout: Self.timeout))

        // After reorder, Bravo's cell should sit above Alpha's.
        let bravoY = element("card.row.Card Bravo").frame.minY
        let alphaY = element("card.row.Card Alpha").frame.minY
        XCTAssertLessThan(bravoY, alphaY, "Reordered card order did not persist across reload")

        leaveDeckToList()
        trashDeck(deck)
    }

    // MARK: - Helpers

    /// Add a card with just a title from the deck-detail screen, returning to the
    /// deck's card list afterward. Handles both the empty-state and the in-list
    /// Add Card buttons.
    private func addCard(titled cardTitle: String) {
        let addButton = element("deck.addCard").exists ? element("deck.addCard")
                                                       : element("deck.addCard.empty")
        XCTAssertTrue(addButton.waitForExistence(timeout: Self.timeout), "No Add Card button found")
        addButton.tap()

        let title = waitFor("cardEditor.title")
        title.tap(); title.typeText(cardTitle)
        waitFor("cardEditor.save").tap()

        // Create now returns straight to the deck (it uploads any staged images
        // first, then closes — no more "stay open in edit mode" detour).
        XCTAssertTrue(
            element("card.row.\(cardTitle)").waitForExistence(timeout: Self.timeout),
            "Card '\(cardTitle)' did not appear after add"
        )
    }
}
