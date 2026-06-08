import XCTest
@testable import PoseDeckCore

/// Regression for SWIFT-A2: concurrent guest grants must be serialized. The
/// share screen exposes two paths into the same grant flow — the Share button
/// and the email field's `.onSubmit` (keyboard Return). The view's
/// `isSubmitting` `@State` only disables the Button, not `.onSubmit`, so a
/// Return racing a Share tap (or two rapid Returns) could invoke the grant twice
/// and each spawn a separate `grantGuest` round-trip for the same email.
/// `GuestGrantGate` models the serialization invariant the view model now uses:
/// only one grant may be in flight, and an overlapping invocation while busy is
/// a no-op (matching `ReorderGate` / the web submitting flag).
final class GuestGrantGateTests: XCTestCase {

    func testStartsIdle() {
        let gate = GuestGrantGate()
        XCTAssertFalse(gate.isBusy)
    }

    func testBeginSucceedsWhenIdleAndMarksBusy() {
        var gate = GuestGrantGate()
        XCTAssertTrue(gate.begin(), "first grant should be allowed to begin")
        XCTAssertTrue(gate.isBusy, "gate must be busy while a grant is in flight")
    }

    /// The core SWIFT-A2 invariant: a second `begin()` while the first grant is
    /// still in flight is rejected, so the overlapping Return/tap is dropped
    /// rather than spawning a second grant round-trip for the same email.
    func testSecondBeginIsRejectedWhileInFlight() {
        var gate = GuestGrantGate()
        XCTAssertTrue(gate.begin())
        XCTAssertFalse(gate.begin(), "a second grant must be blocked while one is in flight")
        XCTAssertTrue(gate.isBusy)
    }

    func testFinishReopensTheGate() {
        var gate = GuestGrantGate()
        XCTAssertTrue(gate.begin())
        gate.finish()
        XCTAssertFalse(gate.isBusy, "gate must reopen after the grant settles")
        XCTAssertTrue(gate.begin(), "a fresh grant should be allowed once the previous one finished")
    }

    /// Even if `finish()` runs on an already-open gate (e.g. a `defer` after an
    /// early-return path such as the empty-email guard), it stays open and does
    /// not corrupt state.
    func testFinishIsIdempotentWhenNotBusy() {
        var gate = GuestGrantGate()
        gate.finish()
        XCTAssertFalse(gate.isBusy)
        XCTAssertTrue(gate.begin())
    }

    /// Simulates the exact bug scenario as a sequence: the Share tap begins a
    /// grant (suspends at its `await`), the field's `.onSubmit` (keyboard Return)
    /// fires while that is in flight and is rejected (no second overlapping
    /// round-trip for the same email), the first grant finishes, then a later
    /// deliberate grant is allowed. The number of admitted grants equals the
    /// number of non-overlapping invocations, never the total number of UI events.
    func testOverlappingSubmitAndReturnAdmitOnlyOneGrant() {
        var gate = GuestGrantGate()
        var admitted = 0

        // Share tap: admitted, now in flight (suspended at await).
        if gate.begin() { admitted += 1 }
        // .onSubmit (keyboard Return) fires before the first grant settles -> rejected.
        if gate.begin() { admitted += 1 }
        // First grant settles (defer { grantGate.finish() }).
        gate.finish()
        // A later, deliberate grant fires after the first settled -> admitted.
        if gate.begin() { admitted += 1 }
        gate.finish()

        XCTAssertEqual(
            admitted, 2,
            "only the two non-overlapping invocations should be admitted, not all three UI events"
        )
    }
}
