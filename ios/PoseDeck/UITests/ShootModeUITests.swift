import XCTest

/// M4 shoot mode — drives the running app through a full shoot session.
///
/// The session is advanced via the **accessibility-action buttons**
/// (`shoot.action.done` / `.skip` / `.undo`) which call the same view-model
/// methods as the swipe gestures, never raw swipe physics (the M3 lesson: the
/// simulator must exercise real runtime logic, and swipe physics is hand-verified
/// on-device rather than in CI). Creates a deck with 3 cards, shoots through it,
/// and cleans up by trashing the deck.
final class ShootModeUITests: PoseDeckUITestCase {

    /// Create a deck and open its detail screen.
    private func openDeck(_ name: String) {
        createDeck(named: name)
        revealDeck(name).tap()
        XCTAssertTrue(
            app.navigationBars[name].waitForExistence(timeout: Self.timeout),
            "Deck detail for '\(name)' did not open"
        )
    }

    /// Add a card with just a title from the deck-detail screen, returning to the
    /// deck's card list afterward. Handles both the empty-state and in-list Add
    /// buttons (mirrors CardUITests.addCard).
    private func addCard(titled cardTitle: String) {
        let addButton = element("deck.addCard").exists ? element("deck.addCard")
                                                       : element("deck.addCard.empty")
        XCTAssertTrue(addButton.waitForExistence(timeout: Self.timeout), "No Add Card button found")
        addButton.tap()

        let title = waitFor("cardEditor.title")
        title.tap(); title.typeText(cardTitle)
        waitFor("cardEditor.save").tap()

        // Create-mode save stays in the editor (edit mode); go back to the deck.
        navigateBack()
        XCTAssertTrue(
            element("card.row.\(cardTitle)").waitForExistence(timeout: Self.timeout),
            "Card '\(cardTitle)' did not appear after add"
        )
    }

    /// Full shoot flow: start → progress → done advances → skip badges → undo
    /// reverses → act on all → complete.
    func testShootSessionFlow() {
        launchAndSignIn()
        let deck = deckName("shoot")
        openDeck(deck)

        addCard(titled: "Shot One")
        addCard(titled: "Shot Two")
        addCard(titled: "Shot Three")

        // Enter shoot mode.
        waitFor("deck.startShoot", "Start-shoot button missing").tap()

        // Card 1 of 3 with the image-prominent current card.
        XCTAssertTrue(
            waitFor("shoot.card-image", "Shoot card image missing").exists
        )
        let progress = waitFor("shoot.progress", "Progress indicator missing")
        XCTAssertEqual(progress.label, "Card 1 of 3", "Should start at card 1 of 3")

        // Mark done → progress advances.
        waitFor("shoot.action.done", "Done action hook missing").tap()
        XCTAssertTrue(
            waitForLabel("shoot.progress", "Card 2 of 3"),
            "Progress did not advance after marking done (got '\(element("shoot.progress").label)')"
        )

        // Skip → skipped badge shows "+1 skipped".
        waitFor("shoot.action.skip", "Skip action hook missing").tap()
        let skipped = waitFor("shoot.skipped-count", "Skipped badge did not appear")
        XCTAssertEqual(skipped.label, "+1 skipped", "Skipped badge should read +1 skipped")

        // Undo → the skip is reversed (badge gone).
        waitFor("shoot.action.undo", "Undo action hook missing").tap()
        XCTAssertFalse(
            element("shoot.skipped-count").waitForExistence(timeout: 5),
            "Skipped badge should disappear after undoing the skip"
        )

        // Act on every remaining card → complete end state.
        // After the undo we are back on card 2; done it, then done card 3.
        waitFor("shoot.action.done").tap()
        waitFor("shoot.action.done").tap()
        XCTAssertTrue(
            waitFor("shoot.complete", "Complete end state did not appear").exists,
            "Session should be complete after acting on all cards"
        )

        // Re-shoot (item 3): "Shoot again" resets the deck back to Card 1 of 3
        // with the skipped badge cleared.
        waitFor("shoot.reshoot", "Shoot-again button missing").tap()
        XCTAssertTrue(
            waitForLabel("shoot.progress", "Card 1 of 3"),
            "Re-shoot should return to Card 1 of 3 (got '\(element("shoot.progress").label)')"
        )
        XCTAssertFalse(
            element("shoot.skipped-count").waitForExistence(timeout: 3),
            "Re-shoot should clear the skipped badge"
        )

        // Exit + clean up.
        if element("shoot.exit").exists { element("shoot.exit").tap() }
        leaveDeckToList()
        trashDeck(deck)
    }

    /// `[GAUNTLET-1 + #2]` swipe-gesture regression — the gap the button-driven
    /// flow above never exercises. The fly-off animation + the parent `@State`
    /// `dragOffset` reset (`[GAUNTLET-1]`) and the stale-completion guard
    /// (`[GAUNTLET-2]`) are only reachable through real swipe physics, so this
    /// drives `swipeRight()` (= done, DESIGN §4.2) / `swipeLeft()` (= skip) on the
    /// `shoot.card-image` element and asserts:
    ///   (a) the next card's progress is VISIBLE after the swipe — catches the
    ///       off-screen render where `dragOffset` stayed at ±700 (#1), and
    ///   (b) progress advances by EXACTLY ONE per swipe — catches the
    ///       double-advance where a fly-off completion fired after an advance (#2),
    ///   (c) the card image stays hittable + centred within the screen after the
    ///       swipe-advance (belt-and-suspenders for #1 if a label read flakes).
    func testShootSwipeAdvancesExactlyOnePerSwipe() {
        launchAndSignIn()
        let deck = deckName("swipe")
        openDeck(deck)

        // Position-ordered shoot order: One, Two, Three.
        addCard(titled: "Swipe One")
        addCard(titled: "Swipe Two")
        addCard(titled: "Swipe Three")

        waitFor("deck.startShoot", "Start-shoot button missing").tap()

        let card = waitFor("shoot.card-image", "Shoot card image missing")
        XCTAssertEqual(
            waitFor("shoot.progress", "Progress indicator missing").label,
            "Card 1 of 3", "Should start at card 1 of 3"
        )
        // The card title is the unambiguous "which card is shown" signal — used to
        // prove advance-by-EXACTLY-one (#2): a double-advance would skip a title.
        XCTAssertTrue(waitForLabel("shoot.card-title", "Swipe One"),
                      "Should start on 'Swipe One' (got '\(element("shoot.card-title").label)')")

        // Swipe RIGHT = done (DESIGN §4.2) → advance EXACTLY one: One → Two.
        card.swipeRight()
        XCTAssertTrue(
            waitForLabel("shoot.card-title", "Swipe Two"),
            "Swipe-right (done) should advance by exactly one to 'Swipe Two' (got '\(element("shoot.card-title").label)')"
        )
        // Progress also advances by one (catches #1's off-screen render too).
        XCTAssertTrue(waitForLabel("shoot.progress", "Card 2 of 3"),
                      "Progress should read Card 2 of 3 after the done swipe")
        assertCardCentredAndHittable("after swipe-right advance")

        // Swipe LEFT = skip → the skipped card (Two) moves to the END, so the next
        // PRESENTED card is Three (advance by exactly one card shown). The cursor
        // position stays at 2 of 3 by design (skip moves the card, not the cursor).
        card.swipeLeft()
        XCTAssertTrue(
            waitForLabel("shoot.card-title", "Swipe Three"),
            "Swipe-left (skip) should advance by exactly one to 'Swipe Three' (got '\(element("shoot.card-title").label)')"
        )
        assertCardCentredAndHittable("after swipe-left advance")

        // EXACTLY one card was skipped — a double-advance would have consumed an
        // extra card and shown "+2 skipped" or skipped past a title (#2).
        let skipped = waitFor("shoot.skipped-count", "Skipped badge did not appear after swipe-left skip")
        XCTAssertEqual(skipped.label, "+1 skipped", "Exactly one card should be skipped (no double-advance)")

        // Exit + clean up.
        if element("shoot.exit").exists { element("shoot.exit").tap() }
        leaveDeckToList()
        trashDeck(deck)
    }

    /// Assert the shoot card image is present, hittable, and its frame is centred
    /// within the screen bounds — i.e. it did NOT render off-screen at a stale
    /// fly-off offset (`[GAUNTLET-1]`).
    private func assertCardCentredAndHittable(_ context: String) {
        let card = element("shoot.card-image")
        XCTAssertTrue(card.waitForExistence(timeout: Self.timeout), "Card image missing \(context)")
        XCTAssertTrue(card.isHittable, "Card image not hittable (likely off-screen) \(context)")
        let screen = app.windows.firstMatch.frame
        let frame = card.frame
        XCTAssertTrue(
            screen.intersection(frame).width > frame.width * 0.6,
            "Card image is mostly off-screen \(context): frame=\(frame) screen=\(screen)"
        )
        XCTAssertGreaterThan(frame.midX, screen.minX, "Card image pushed off the left edge \(context)")
        XCTAssertLessThan(frame.midX, screen.maxX, "Card image pushed off the right edge \(context)")
    }

    /// Poll an element's label until it matches (XCUITest labels update lazily).
    private func waitForLabel(_ id: String, _ expected: String, timeout: TimeInterval = timeout) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element(id).label == expected { return true }
            usleep(150_000)
        }
        return element(id).label == expected
    }
}
