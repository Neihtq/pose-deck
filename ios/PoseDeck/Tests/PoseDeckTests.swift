import XCTest
@testable import PoseDeck

/// Stub unit-test target for the app shell.
///
/// Logic-heavy tests live in the PoseDeckCore package (`swift test`). This
/// target exists so the app project has a wired-up test bundle for the
/// integration agent to grow UI/integration tests into.
final class PoseDeckTests: XCTestCase {
    /// AppConfig must always resolve to a usable URL, even when Info.plist is
    /// missing the key in the test bundle context.
    func testAppConfigFallsBackToDefaultBaseURL() {
        // In the test host the Info.plist key may be absent; the resolver must
        // still produce a valid URL rather than crashing.
        XCTAssertFalse(AppConfig.apiBaseURLString.isEmpty)
        XCTAssertNotNil(URL(string: AppConfig.apiBaseURLString))
    }
}
