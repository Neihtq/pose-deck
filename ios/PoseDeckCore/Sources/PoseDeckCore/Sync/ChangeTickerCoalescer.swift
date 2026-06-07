import Foundation

/// Pure coalescing logic behind the app-target `MirrorChangeTicker` (M3 plan,
/// STEP 10).
///
/// The mirror-change ticker exists so views that read through the mirror
/// repositories re-query after a realtime merge / outbox confirmation without
/// each owning a SwiftData `@Query`. A backfill or a burst of realtime events
/// fires many `ModelContext.didSave` notifications in quick succession; bumping
/// the observed `revision` on every one would stampede every observing view into
/// a re-query per event. So the ticker debounces: it coalesces a burst into a
/// single bump after a quiet window.
///
/// The *timing* (the debounce sleep) lives in the app-target ticker because it
/// depends on `Task.sleep` and the main actor, but the *bookkeeping* — recording
/// that changes are pending and computing the single resulting bump — is a tiny,
/// side-effect-free value type so the coalescing contract is unit-testable in
/// `PoseDeckCore`, independent of SwiftData. Mirrors the role of ``ReorderGate``
/// and ``ThumbnailRefresh`` (other app-glue logic lifted into the core for tests).
///
/// Contract:
///  - ``noteChange()`` records that at least one mirror change is pending.
///  - ``flush()`` collapses *all* pending changes into a single `revision` bump
///    (so the burst refreshes the UI exactly once) and returns the new revision;
///    a `flush()` with nothing pending is a no-op and returns the unchanged
///    revision, so a stray debounce timer can't bump the UI for no reason.
public struct ChangeTickerCoalescer: Sendable, Equatable {

    /// The monotonically increasing counter observed by views. A change is the
    /// observable side effect; views re-query whenever this value changes.
    public private(set) var revision: Int

    /// Whether at least one change has been noted since the last flush.
    public private(set) var hasPendingChange: Bool

    public init(revision: Int = 0, hasPendingChange: Bool = false) {
        self.revision = revision
        self.hasPendingChange = hasPendingChange
    }

    /// Record that the mirror changed. Any number of calls before the next
    /// ``flush()`` coalesce into a single pending bump.
    public mutating func noteChange() {
        hasPendingChange = true
    }

    /// Collapse all pending changes into one `revision` bump. Returns the
    /// (possibly unchanged) revision. A no-op when nothing is pending so a stray
    /// debounce firing does not churn observing views.
    @discardableResult
    public mutating func flush() -> Int {
        guard hasPendingChange else { return revision }
        hasPendingChange = false
        revision &+= 1
        return revision
    }
}
