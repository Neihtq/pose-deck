import Foundation

/// Observes "the session's auth token has been rejected by the server" and
/// surfaces it exactly once so the app can re-authenticate or sign out, rather
/// than letting realtime die silently and the outbox spin paused forever
/// (swift-4).
///
/// Background: a mid-session 401 makes ``RealtimeClient`` stop its loop (it
/// calls `onAuthFailed` then returns) and makes ``OutboxProcessor`` return
/// ``DrainResult/authPaused`` indefinitely. Neither path performs a token
/// refresh, so without this signal the session silently goes stale until app
/// relaunch — diverging from ARCHITECTURE.md §12 ("Auto-refresh on 401") and
/// from the web reference, where `clearAuthOnUnauthorized` clears the auth
/// store on a 401 and routes the user back to login.
///
/// Until a real refresh flow exists, this reporter is the seam the app wires to
/// drive a sign-out / re-login. It is an `actor` so both the realtime loop and
/// the outbox drain loop can report from their own isolation domains, and it
/// **de-duplicates**: the injected handler fires only on the first report after
/// each ``reset()`` (a single 401 can surface from both subscriptions at once).
public actor SessionExpiryReporter {

    private var onExpired: @Sendable () async -> Void
    private var reported = false

    /// - Parameter onExpired: invoked the first time ``reportExpired()`` is
    ///   called after construction or ``reset()``. The app wires this to its
    ///   sign-out / re-auth flow. Owners that must construct the reporter before
    ///   `self` is available (e.g. a `@MainActor` coordinator) can pass the
    ///   default and call ``setHandler(_:)`` afterwards.
    public init(onExpired: @escaping @Sendable () async -> Void = {}) {
        self.onExpired = onExpired
    }

    /// Replace the expiry handler after construction. If an expiry was already
    /// reported before the handler was installed, the new handler fires
    /// immediately so a 401 racing initialization is not dropped.
    public func setHandler(_ handler: @escaping @Sendable () async -> Void) async {
        self.onExpired = handler
        if reported { await handler() }
    }

    /// Whether an expiry has been reported and not yet ``reset()``.
    public var hasExpired: Bool { reported }

    /// Record that the session token was rejected (a 401). Fires `onExpired`
    /// exactly once per expiry episode; subsequent calls are no-ops until
    /// ``reset()`` (so realtime + outbox both reporting the same 401 only
    /// trigger one sign-out).
    public func reportExpired() async {
        guard !reported else { return }
        reported = true
        await onExpired()
    }

    /// Clear the latched state after a successful (re)authentication, so a
    /// future expiry is reported again.
    public func reset() {
        reported = false
    }
}
