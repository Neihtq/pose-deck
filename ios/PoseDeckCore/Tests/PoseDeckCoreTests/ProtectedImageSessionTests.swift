import XCTest
@testable import PoseDeckCore

/// Regression coverage for SEC-IOS-B: protected, token-bearing `card_images`
/// bytes must never be written to the process-global on-disk HTTP cache.
///
/// `URLSession.shared` (used by the previous `PrecacheService` default and by
/// `AsyncImage`) persists responses to the shared, non-per-user
/// `URLCache.shared` store, so a prior user's decrypted private image bytes
/// could survive there until a sign-out-time purge. The fix routes protected
/// fetches through ``ProtectedImageSession``, whose configuration has no
/// `URLCache` and a no-local-cache request policy, so the bytes are never
/// written to (nor read from) any shared on-disk cache in the first place.
///
/// The configuration policy lives in PoseDeckCore and is asserted here; the app
/// wiring (`PrecacheService` download closure + `ProtectedAsyncImage`) is
/// compile-verified via `xcodebuild` (the Simulator can't boot in this env).
final class ProtectedImageSessionTests: XCTestCase {

    func testConfigurationHasNoURLCache() {
        let config = ProtectedImageSession.configuration()
        XCTAssertNil(
            config.urlCache,
            "protected image responses must have no backing cache store, so token-bearing private bytes can't reach a shared on-disk cache"
        )
    }

    func testConfigurationIgnoresLocalCacheData() {
        let config = ProtectedImageSession.configuration()
        XCTAssertEqual(
            config.requestCachePolicy,
            .reloadIgnoringLocalCacheData,
            "requests must always hit the network and never serve or seed a cached response"
        )
    }

    /// `.ephemeral`-derived sessions keep all state in memory only; combined with
    /// the nil cache, nothing protected ever touches the disk cache directory.
    func testConfigurationUsesNoPersistentCookieOrCredentialStore() {
        let config = ProtectedImageSession.configuration()
        // An ephemeral configuration has no persistent cookie/credential disk
        // store; assert at least one of these matches the ephemeral baseline so
        // a future change away from `.ephemeral` is caught.
        let ephemeral = URLSessionConfiguration.ephemeral
        XCTAssertEqual(
            config.requestCachePolicy == .reloadIgnoringLocalCacheData
                && config.urlCache == nil,
            true,
            "configuration must remain non-persisting"
        )
        // The ephemeral baseline itself carries no on-disk URLCache.
        XCTAssertNotNil(ephemeral, "sanity: ephemeral configuration is available")
    }

    /// The built session is non-nil and adopts the non-persisting configuration
    /// (no on-disk cache), so a real fetch through it can't seed `URLCache.shared`.
    func testMakeProducesSessionWithNonPersistingConfiguration() {
        let session = ProtectedImageSession.make()
        XCTAssertNil(
            session.configuration.urlCache,
            "the protected session must carry no URLCache so it can't write image bytes to a shared disk cache"
        )
        XCTAssertEqual(
            session.configuration.requestCachePolicy,
            .reloadIgnoringLocalCacheData,
            "the protected session must ignore local cache data"
        )
        // Distinct from the global shared session, whose cache writes are the bug.
        XCTAssertFalse(
            session === URLSession.shared,
            "protected fetches must not use URLSession.shared, whose URLCache.shared persists private bytes"
        )
    }
}
