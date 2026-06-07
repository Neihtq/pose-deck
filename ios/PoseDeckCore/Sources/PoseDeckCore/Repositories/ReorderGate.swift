import Foundation

/// Serializes optimistic card reorders so a new drag cannot start while a
/// previous `reorderCards` persist is still in flight (ARCHITECTURE.md §3.3 /
/// web `DeckDetailPage` `reordering` flag).
///
/// Why this exists: a deck-detail view applies a reorder optimistically (mutate
/// the local card array, then `await` the per-card PATCH loop). The mutating
/// view model is `@MainActor`, so the synchronous prologue of one move cannot
/// interleave with another — but a move *suspends* at the `await`, and while
/// suspended a second `.onMove` can fire and stack a second optimistic reorder
/// on top of the first's unconfirmed state, launching a second non-atomic PATCH
/// loop that can interleave server writes with the first. The web reference
/// guards this exact case with a `reordering` flag and an early-return.
///
/// This is a tiny, pure value type (no actor / no I/O) so the gate decision is
/// unit-testable in `PoseDeckCore`, while the owning view model holds one
/// instance and flips `isBusy` around its `await`.
public struct ReorderGate: Sendable, Equatable {
    /// True while a reorder is being persisted. Callers should bind this to
    /// disable drag in the UI (mirrors the web `dragDisabled={reordering}`).
    public private(set) var isBusy: Bool

    /// Set when a mirror re-query (realtime / outbox-confirmation / ticker bump)
    /// arrived *while* a reorder was in flight and was therefore skipped. The
    /// reorder's exit path consults this to run exactly one coalesced refresh
    /// after it settles, so the screen still converges to the merged remote
    /// state without clobbering the optimistic order mid-flight. See `swift-1`.
    public private(set) var pendingRefresh: Bool

    public init(isBusy: Bool = false) {
        self.isBusy = isBusy
        self.pendingRefresh = false
    }

    /// Attempt to begin a reorder. Returns `true` and marks the gate busy when
    /// no reorder is in flight; returns `false` (a no-op) when one already is, so
    /// the caller can drop the overlapping drop rather than stacking it.
    ///
    /// Mutating + return-value so the caller does `guard gate.begin() else { return }`,
    /// matching the web early-return guard in `handleDragEnd`.
    public mutating func begin() -> Bool {
        if isBusy { return false }
        isBusy = true
        return true
    }

    /// Mark the in-flight reorder finished, re-opening the gate. Safe to call
    /// even when not busy. Intended for a `defer` so it runs on every exit path.
    /// Does not clear `pendingRefresh` — the caller drains that separately via
    /// `takePendingRefresh()` so a coalesced re-query runs after the gate reopens.
    public mutating func finish() {
        isBusy = false
    }

    /// Record that a mirror re-query should run. While a reorder is in flight a
    /// concurrent re-read of the mirror would overwrite the optimistic order with
    /// a partially-restriped (neither-old-nor-new) ordering — the `swift-1`
    /// actor-interleaving window — so callers skip the re-read and call this to
    /// remember that one is owed. Returns `true` when the refresh should be run
    /// *now* (the gate is idle), and `false` when it was deferred (busy), so the
    /// caller can `guard gate.requestRefresh() else { return }`.
    public mutating func requestRefresh() -> Bool {
        if isBusy {
            pendingRefresh = true
            return false
        }
        return true
    }

    /// Consume any deferred refresh recorded during the in-flight window,
    /// clearing the flag. Returns `true` exactly once per coalesced batch of
    /// skipped re-queries, so the reorder's exit path runs a single catch-up
    /// refresh after the gate reopens.
    public mutating func takePendingRefresh() -> Bool {
        defer { pendingRefresh = false }
        return pendingRefresh
    }
}
