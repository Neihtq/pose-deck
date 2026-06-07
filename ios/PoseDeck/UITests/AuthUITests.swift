import XCTest

/// M2 checklist — authentication + session persistence.
final class AuthUITests: PoseDeckUITestCase {

    /// Sign in with the seeded credentials → lands on the deck list.
    func testSignInSucceeds() {
        launchAndSignIn()
        XCTAssertTrue(app.navigationBars["Decks"].exists)
    }

    /// Wrong password surfaces the inline error and does not navigate.
    func testSignInWrongPasswordShowsError() {
        launchReset()
        let email = app.textFields["Email"]
        XCTAssertTrue(email.waitForExistence(timeout: Self.timeout))
        email.tap(); email.typeText(Self.email)
        let password = app.secureTextFields["Password"]
        password.tap(); password.typeText("wrong-password")
        app.buttons["login.submit"].tap()

        XCTAssertTrue(
            app.staticTexts["login.error"].waitForExistence(timeout: Self.timeout),
            "Expected an inline sign-in error"
        )
        XCTAssertFalse(app.navigationBars["Decks"].exists, "Should not navigate on bad credentials")
    }

    /// Session persists across relaunch via the Keychain: after a clean sign-in,
    /// relaunching WITHOUT a reset should restore straight to the deck list with
    /// no login screen.
    func testSessionPersistsAcrossRelaunch() {
        // First run: clean sign-in, which persists the session to the keychain.
        launchAndSignIn()
        app.terminate()

        // Second run: no reset, no re-entry of credentials.
        launchKeepingSession()
        XCTAssertTrue(
            app.navigationBars["Decks"].waitForExistence(timeout: Self.timeout),
            "Persisted session was not restored — landed somewhere other than the deck list"
        )
        XCTAssertFalse(
            app.textFields["Email"].exists,
            "Login screen appeared despite a persisted session"
        )

        // Cleanup: leave the device signed out for the next test's reset path.
        let signOut = element("decks.signOut")
        if signOut.exists { signOut.tap() }
    }

    /// Sign out returns to the login screen.
    func testSignOutReturnsToLogin() {
        launchAndSignIn()
        waitFor("decks.signOut", "Sign Out button missing").tap()
        XCTAssertTrue(
            app.textFields["Email"].waitForExistence(timeout: Self.timeout),
            "Did not return to the login screen after sign out"
        )
    }
}
