import XCTest

/// Base case for the M2 on-device verification suite.
///
/// These tests drive the *running app* against the live PocketBase dev backend
/// (see STATUS.md — the backend must be up at `http://localhost:8090`, which the
/// simulator reaches as the host's `localhost`). They are the executable form of
/// the M2 manual checklist, now runnable since the simulator works.
///
/// Each test launches a fresh app with `-uitest-reset` (which clears the keychain
/// session before the app reads it) and signs in, so runs are independent and
/// deterministic regardless of a previously persisted session. Created decks use
/// a per-run unique prefix and are moved to Trash at the end of each test to keep
/// the shared dev database from accumulating fixtures.
class PoseDeckUITestCase: XCTestCase {
    /// Seeded dev credentials (STATUS.md).
    static let email = "owner@posedeck.test"
    static let password = "changeme123"

    /// Default wait for network-backed UI to settle.
    static let timeout: TimeInterval = 20

    var app: XCUIApplication!
    /// Unique per-test prefix so concurrently-seeded fixtures never collide and
    /// assertions match only this run's decks.
    var runPrefix: String!

    override func setUpWithError() throws {
        continueAfterFailure = false
        runPrefix = "UITest-\(Int(Date().timeIntervalSince1970))-\(UInt32.random(in: 0..<99999))"
        app = XCUIApplication()
    }

    // MARK: - Launch / auth helpers

    /// Launch with a clean (reset) session.
    func launchReset() {
        app.launchArguments = ["-uitest-reset"]
        app.launch()
    }

    /// Launch reusing whatever session is persisted (no reset) — used by the
    /// session-persistence test to prove the keychain restore path.
    func launchKeepingSession() {
        app.launchArguments = []
        app.launch()
    }

    /// Sign in through the login form and wait for the deck list to appear.
    func signIn() {
        let email = app.textFields["Email"]
        XCTAssertTrue(email.waitForExistence(timeout: Self.timeout), "Login screen did not appear")
        email.tap()
        email.typeText(Self.email)

        let password = app.secureTextFields["Password"]
        password.tap()
        password.typeText(Self.password)

        app.buttons["login.submit"].tap()
        XCTAssertTrue(app.navigationBars["Decks"].waitForExistence(timeout: Self.timeout), "Did not land on the deck list after sign-in")
    }

    /// Launch fresh, reset the session, and sign in. The common test preamble.
    @discardableResult
    func launchAndSignIn() -> XCUIApplication {
        launchReset()
        signIn()
        return app
    }

    // MARK: - Element lookup

    /// Find an element by accessibility identifier across the element types our
    /// SwiftUI views surface it as (a List `NavigationLink`/`Button` can resolve
    /// to a button, cell, or other-element depending on context).
    func element(_ id: String) -> XCUIElement {
        let q = app.descendants(matching: .any).matching(identifier: id)
        return q.firstMatch
    }

    /// Wait for an identified element to exist; returns it for chaining.
    @discardableResult
    func waitFor(_ id: String, timeout: TimeInterval = timeout, _ message: String = "") -> XCUIElement {
        let el = element(id)
        XCTAssertTrue(
            el.waitForExistence(timeout: timeout),
            message.isEmpty ? "Element '\(id)' never appeared" : message
        )
        return el
    }

    /// A precisely-typed button by identifier. Use for state checks
    /// (`isEnabled`) where the generic `element(_:)` could resolve to a wrapper
    /// whose enabled-state does not reflect the button's.
    func button(_ id: String) -> XCUIElement { app.buttons[id] }

    /// Pop the navigation stack one level via the back button.
    func navigateBack() {
        let back = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: Self.timeout), "Back button missing")
        back.tap()
    }

    /// From the deck-detail screen, return to the deck list (so list-scoped
    /// helpers like `trashDeck` work). Idempotent-ish: taps back until the
    /// "Decks" nav bar appears.
    func leaveDeckToList() {
        if app.navigationBars["Decks"].exists { return }
        navigateBack()
        XCTAssertTrue(
            app.navigationBars["Decks"].waitForExistence(timeout: Self.timeout),
            "Did not return to the deck list"
        )
    }

    // MARK: - Deck helpers

    /// A run-unique deck name from a short suffix.
    func deckName(_ suffix: String) -> String { "\(runPrefix!)-\(suffix)" }

    /// Create a deck via the New-deck flow. If `dated` is true, toggle on a
    /// shoot date (defaults to today → groups under "Upcoming").
    ///
    /// The deck list is grouped (Upcoming/Undated/Past) and can hold many decks,
    /// so a freshly created deck may sort off-screen — and SwiftUI's lazy List
    /// only exposes on-screen cells to the accessibility tree. We therefore
    /// confirm creation by searching for the deck (which collapses the list to
    /// just the matches), then clear the search so callers see the normal list.
    func createDeck(named name: String, dated: Bool = false) {
        waitFor("decks.new", "New Deck button missing").tap()

        let nameField = waitFor("deckEditor.name", "Deck name field missing")
        nameField.tap()
        nameField.typeText(name)

        if dated {
            enableShootDate()
        }

        waitFor("deckEditor.save", "Deck save button missing").tap()

        // Verify via search so the row is guaranteed on-screen regardless of how
        // many decks exist or which group this one sorts into.
        XCTAssertTrue(
            searchForDeck(name).waitForExistence(timeout: Self.timeout),
            "Created deck '\(name)' did not appear (searched after save)"
        )
        clearSearch()
    }

    /// Turn on the "Has a shoot date" toggle in the deck editor and confirm the
    /// date picker appears (so the deck is created dated → groups under
    /// "Upcoming"). The toggle is matched by accessibility id and may surface as
    /// a switch or other element type depending on the runtime.
    func enableShootDate() {
        let toggle = element("deckEditor.hasDate")
        XCTAssertTrue(toggle.waitForExistence(timeout: Self.timeout), "Shoot-date toggle missing")
        // A SwiftUI Toggle in a Form exposes the *row* under the identifier (label
        // + switch), so a center tap can land on the label and not flip anything.
        // Tap the trailing edge where the actual switch control sits.
        if (toggle.value as? String) != "1" {
            let knob = toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5))
            knob.tap()
        }
        XCTAssertTrue(
            element("deckEditor.datePicker").waitForExistence(timeout: 5),
            "Date picker did not appear after enabling the shoot-date toggle"
        )
    }

    /// The deck-list row for a name.
    func deckRow(_ name: String) -> XCUIElement { element("deck.row.\(name)") }

    /// Type a deck name into the list's search field and return its row element.
    /// Searching narrows the grouped list to matches so the row is on-screen.
    @discardableResult
    func searchForDeck(_ name: String) -> XCUIElement {
        let search = app.searchFields["Search decks"]
        XCTAssertTrue(search.waitForExistence(timeout: Self.timeout), "Search field missing")
        search.tap()
        // Replace any prior query.
        clearSearchField(search)
        search.typeText(name)
        return deckRow(name)
    }

    /// Clear the deck-list search field if present (so the full list shows).
    func clearSearch() {
        let search = app.searchFields["Search decks"]
        guard search.exists else { return }
        clearSearchField(search)
        // Dismiss the search/keyboard if a Cancel affordance is up.
        let cancel = app.buttons["Cancel"]
        if cancel.exists { cancel.tap() }
    }

    private func clearSearchField(_ search: XCUIElement) {
        let clear = search.buttons["Clear text"]
        if clear.exists { clear.tap() }
    }

    /// Reveal a deck's row via search (so it is on-screen) and return it. Use
    /// before swipe / context-menu / tap operations in a list that may be large.
    @discardableResult
    func revealDeck(_ name: String) -> XCUIElement {
        let row = searchForDeck(name)
        XCTAssertTrue(row.waitForExistence(timeout: Self.timeout), "Deck '\(name)' not found via search")
        return row
    }

    /// Move a deck to Trash via swipe + confirmation dialog. Best-effort cleanup.
    /// Reveals the row via search first so it is reliably on-screen.
    func trashDeck(_ name: String) {
        let row = searchForDeck(name)
        guard row.waitForExistence(timeout: 8) else { clearSearch(); return }
        row.swipeLeft()
        let delete = app.buttons["Delete"]
        if delete.waitForExistence(timeout: 5) { delete.tap() }
        let confirm = app.buttons["Move to Trash"]
        if confirm.waitForExistence(timeout: 5) { confirm.tap() }
        clearSearch()
    }
}
