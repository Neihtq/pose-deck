import XCTest

/// M2 checklist — card images.
///
/// NOTE on coverage split: the picked-photo → compress → STAGE → upload-on-create
/// pipeline is exhaustively covered by the deterministic unit tests in
/// `PoseDeckTests/CardImageStagingTests` (no cross-process picker). Driving the
/// system PhotosPicker from XCUITest is unreliable (a separate process whose grid
/// cells aren't dependably hittable), so this UI test asserts only what it can do
/// robustly: that the image section is now available on a brand-new, unsaved card
/// (the UX fix — no "save first" gate) and that the upload affordances are live.
final class ImageUploadUITests: PoseDeckUITestCase {

    /// The image section is present and usable BEFORE a new card is saved — you
    /// can add photos straight away instead of having to tap "Create" first.
    func testNewCardImageSectionAvailableBeforeSave() {
        launchAndSignIn()
        let deck = deckName("images")
        createDeck(named: deck)
        revealDeck(deck).tap()
        XCTAssertTrue(app.navigationBars[deck].waitForExistence(timeout: Self.timeout))

        // Open the NEW-card editor (title still empty → unsaved, "Create" mode).
        waitFor("deck.addCard.empty").tap()

        // The image section is present immediately, starting empty — previously
        // this was gated behind a first save.
        let count = waitFor("cardImages.count", "Image section must be available on a new card before saving")
        XCTAssertEqual(count.label, "Images (0/5)", "New card starts with no images")

        // The add affordances are live (not disabled behind a save gate).
        XCTAssertTrue(
            waitFor("cardImages.add", "Add image button missing").isEnabled,
            "Add image must be enabled on an unsaved new card"
        )

        // Cleanup: back out without creating, then trash the deck.
        app.navigationBars.buttons.firstMatch.tap() // editor → deck
        app.navigationBars.buttons.firstMatch.tap() // deck → list
        trashDeck(deck)
    }
}
