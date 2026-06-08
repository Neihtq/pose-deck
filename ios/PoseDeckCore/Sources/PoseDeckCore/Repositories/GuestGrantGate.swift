import Foundation

/// Serializes in-flight deck-sharing grants so two overlapping `grantGuest`
/// calls for the same email cannot both spawn a network round-trip (SWIFT-A2 /
/// web `ShareDeckDialog`'s submitting flag).
///
/// Why this exists: the share screen's "add by email" field exposes *two* paths
/// that invoke the same grant flow — the Share button and the text field's
/// `.onSubmit` (keyboard Return). The view's `isSubmitting` `@State` only
/// disables the Button; it does NOT gate `.onSubmit`. So a keyboard Return
/// racing a Share tap (or two rapid Returns) could invoke the grant twice and
/// each spawn a separate `grantGuest` Task for the same email. The owning view
/// model is `@MainActor`, which serializes the *synchronous* prologue of each
/// call — but both calls still run to completion and each suspend at `await`,
/// so a flag that is never consulted inside the grant flow does not prevent the
/// double-spawn. The server composite-unique constraint makes the duplicate an
/// idempotent no-op, so worst case is a redundant round-trip and a benign
/// "already shared" message — but the redundant work should be elided at source.
///
/// Putting the guard *inside* the grant flow (rather than only on the Button)
/// closes every caller path with one flag, matching the in-flight short-circuit
/// pattern used elsewhere (`ReorderGate.begin`, `ImageUploadGate.busy`).
///
/// This is a tiny, pure value type (no actor / no I/O) so the gate decision is
/// unit-testable in `PoseDeckCore`, while the owning view model holds one
/// instance and flips `isBusy` around its `await`.
public struct GuestGrantGate: Sendable, Equatable {
    /// True while a grant is being persisted. Callers may bind this to disable
    /// the share controls in the UI (mirrors the web submitting flag).
    public private(set) var isBusy: Bool

    public init(isBusy: Bool = false) {
        self.isBusy = isBusy
    }

    /// Attempt to begin a grant. Returns `true` and marks the gate busy when no
    /// grant is in flight; returns `false` (a no-op) when one already is, so the
    /// caller can drop the overlapping invocation rather than spawning a second
    /// network round-trip.
    ///
    /// Mutating + return-value so the caller does `guard gate.begin() else { return }`
    /// at the top of the grant flow — guarding the Button and `.onSubmit` paths
    /// with the same in-flight flag.
    public mutating func begin() -> Bool {
        if isBusy { return false }
        isBusy = true
        return true
    }

    /// Mark the in-flight grant finished, re-opening the gate. Safe to call even
    /// when not busy. Intended for a `defer` so it runs on every exit path.
    public mutating func finish() {
        isBusy = false
    }
}
