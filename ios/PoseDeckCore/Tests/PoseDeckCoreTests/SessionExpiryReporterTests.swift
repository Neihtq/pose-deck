import XCTest
@testable import PoseDeckCore

/// Regression coverage for ``SessionExpiryReporter`` (swift-4).
///
/// A mid-session 401 made realtime stop forever (`onAuthFailed` was a no-op) and
/// left the outbox `authPaused`, busy-idling the drain loop every 5s with no
/// refresh — so the session silently went stale until app relaunch. The fix
/// routes both the realtime `onAuthFailed` and the outbox `.authPaused` case
/// through this reporter, which fires a one-shot signal the app uses to sign out
/// / re-login (web parity with `clearAuthOnUnauthorized`).
final class SessionExpiryReporterTests: XCTestCase {

    /// A thread-safe counter the @Sendable handler can bump.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.withLock { n += 1 } }
        var value: Int { lock.withLock { n } }
    }

    func testReportsExactlyOncePerEpisode() async {
        let counter = Counter()
        let reporter = SessionExpiryReporter { counter.bump() }

        // Both realtime and the outbox can observe the same 401 concurrently;
        // the handler must fire only once.
        await reporter.reportExpired()
        await reporter.reportExpired()
        await reporter.reportExpired()

        XCTAssertEqual(counter.value, 1, "a single expiry episode signals the app once")
        let expired = await reporter.hasExpired
        XCTAssertTrue(expired)
    }

    func testResetAllowsReportingAgain() async {
        let counter = Counter()
        let reporter = SessionExpiryReporter { counter.bump() }

        await reporter.reportExpired()
        XCTAssertEqual(counter.value, 1)

        // After a fresh (re)authentication the coordinator resets the latch.
        await reporter.reset()
        let afterReset = await reporter.hasExpired
        XCTAssertFalse(afterReset, "reset clears the latched expiry")

        await reporter.reportExpired()
        XCTAssertEqual(counter.value, 2, "a later expiry is reported again after reset")
    }

    func testHandlerInstalledAfterExpiryStillFires() async {
        // The app's @MainActor coordinator must construct the reporter before
        // `self` exists, then install the handler via setHandler. A 401 that
        // races that install must NOT be dropped.
        let counter = Counter()
        let reporter = SessionExpiryReporter() // no handler yet

        await reporter.reportExpired() // 401 arrives before the handler is wired
        XCTAssertEqual(counter.value, 0, "no handler installed yet — nothing fires")

        await reporter.setHandler { counter.bump() }
        XCTAssertEqual(counter.value, 1, "installing the handler flushes the pending expiry")

        // Still one-shot: re-reporting does not double-fire.
        await reporter.reportExpired()
        XCTAssertEqual(counter.value, 1)
    }
}
