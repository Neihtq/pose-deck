import XCTest

/// M2 checklist — card images: pick from the photo library, compress + upload,
/// thumbnail renders, count reflects the upload.
///
/// This drives the system PhotosPicker (a separate process), so it is the most
/// fragile test in the suite. It requires a photo seeded into the simulator
/// library first:
///   xcrun simctl addmedia "iPhone 16 Pro" /path/to/photo.jpg
/// The CI/run script seeds one before invoking this test.
final class ImageUploadUITests: PoseDeckUITestCase {

    func testAddImageToCard() {
        launchAndSignIn()
        let deck = deckName("images")
        createDeck(named: deck)
        revealDeck(deck).tap()
        XCTAssertTrue(app.navigationBars[deck].waitForExistence(timeout: Self.timeout))

        // Add a card; create-mode save keeps the editor open in edit mode, where
        // the image section becomes available.
        waitFor("deck.addCard.empty").tap()
        let title = waitFor("cardEditor.title")
        title.tap(); title.typeText("Card with image")
        waitFor("cardEditor.save").tap()

        // Image section is now present (card has an id). Count starts at 0/5.
        let count = waitFor("cardImages.count", "Image count label missing")
        XCTAssertEqual(count.label, "Images (0/5)", "Image section should start empty")

        // Open the system photo picker.
        waitFor("cardImages.add", "Add image button missing").tap()

        // Drive the cross-process PhotosPicker: tap the first photo cell.
        let springboardPhoto = app.scrollViews.images.firstMatch
        let picked: Bool
        if springboardPhoto.waitForExistence(timeout: Self.timeout) {
            springboardPhoto.tap()
            picked = true
        } else {
            // Fallback: some runtimes surface picker cells as images at the app
            // level. Try any image element.
            let anyImage = app.images.firstMatch
            picked = anyImage.waitForExistence(timeout: 5)
            if picked { anyImage.tap() }
        }
        XCTAssertTrue(picked, "Could not select a photo from the picker — is a photo seeded in the simulator library?")

        // After compress + upload, the count should advance to 1/5.
        let expectation = expectation(
            for: NSPredicate(format: "label == %@", "Images (1/5)"),
            evaluatedWith: element("cardImages.count")
        )
        wait(for: [expectation], timeout: Self.timeout)

        // The per-image delete affordance ("Remove image") confirms a thumbnail
        // rendered.
        XCTAssertTrue(
            app.buttons["Remove image"].firstMatch.waitForExistence(timeout: Self.timeout),
            "Uploaded image thumbnail (with Remove control) did not render"
        )

        // Cleanup.
        app.navigationBars.buttons.firstMatch.tap() // editor → deck
        app.navigationBars.buttons.firstMatch.tap() // deck → list
        trashDeck(deck)
    }
}
