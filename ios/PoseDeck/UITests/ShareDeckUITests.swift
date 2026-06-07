import XCTest

/// M5 sharing — owner-only Share UI gating, single-user driveable.
///
/// The realtime grant/revoke propagation across two users cannot be exercised by
/// the single-user XCUITest harness (that logic is covered in PoseDeckCore's
/// `swift test`). What CAN be driven here is the owner-side Share affordance: the
/// deck owner sees "Share" in the deck-actions menu, opening it shows the share
/// sheet, and granting an existing user (`guest@posedeck.test`, seeded in dev)
/// surfaces a guest row.
///
/// Drives the live PocketBase dev backend (see STATUS.md). Self-cleans by
/// trashing the deck.
final class ShareDeckUITests: PoseDeckUITestCase {

    /// A second seeded dev account the owner can share with.
    private static let guestEmail = "guest@posedeck.test"

    /// Open a freshly created deck's detail screen.
    private func openDeck(_ name: String) {
        createDeck(named: name)
        revealDeck(name).tap()
        XCTAssertTrue(
            app.navigationBars[name].waitForExistence(timeout: Self.timeout),
            "Deck detail for '\(name)' did not open"
        )
    }

    /// Open the deck-actions menu and tap Share, then confirm the share screen
    /// appears (a pushed destination, identified by its email field).
    private func openShareScreen() {
        let menu = waitFor("deck.actionsMenu", "Deck-actions menu missing for the owner")
        menu.tap()
        let share = waitFor("deck.share", "Share menu item missing for the owner")
        share.tap()
        XCTAssertTrue(
            waitFor("share.email", "Share screen email field did not appear").exists,
            "Share screen did not open"
        )
    }

    /// The owner sees the Share affordance and opening it shows the share screen.
    func testOwnerSeesShareAndOpensSheet() {
        launchAndSignIn()
        let deck = deckName("share-gate")
        openDeck(deck)

        openShareScreen()

        // Empty state before any grant.
        XCTAssertTrue(
            waitFor("share.empty", "Empty 'shared with' state missing").exists,
            "Expected the not-shared-with-anyone empty state"
        )

        // Return to the deck.
        navigateBack()

        leaveDeckToList()
        trashDeck(deck)
    }

    /// Granting an existing user by email surfaces a guest row in the share screen.
    func testGrantByEmailShowsGuestRow() {
        launchAndSignIn()
        let deck = deckName("share-grant")
        openDeck(deck)

        openShareScreen()

        let email = waitFor("share.email")
        email.tap()
        email.typeText(Self.guestEmail)
        waitFor("share.submit", "Share submit button missing").tap()

        // A guest row appears (a Revoke control becomes available). The row is
        // keyed by user id, so assert the generic Revoke affordance shows up.
        XCTAssertTrue(
            waitFor("share.revoke", "Guest row (with Revoke) did not appear after granting").exists,
            "Granting an existing user should surface a guest row"
        )

        // Revoke it back so the dev DB doesn't accumulate grants, then return.
        waitFor("share.revoke").tap()
        navigateBack()

        leaveDeckToList()
        trashDeck(deck)
    }
}
