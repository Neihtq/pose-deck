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

    public init(isBusy: Bool = false) {
        self.isBusy = isBusy
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
    public mutating func finish() {
        isBusy = false
    }
}
