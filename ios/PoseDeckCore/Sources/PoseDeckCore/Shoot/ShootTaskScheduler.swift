import Foundation

/// Owns the lifecycle of the *unstructured* side-effect work a shoot session
/// fires off (completion persists + image prefetch passes) so that work is
/// cancellable and bounded rather than leaking past the screen (`[FIX-swift-4]`).
///
/// The view model used to spawn bare `Task { … }` blocks for every `done`/`skip`/
/// `undo`: those captured `self`, retained no handle, and could not be cancelled,
/// so pending completion writes and image fetches kept running after the shoot
/// screen was dismissed, and rapid swipes stacked overlapping prefetch passes.
///
/// This `@MainActor` type centralises both jobs:
///  - ``persist(_:)`` retains each fire-and-forget write in a bag, self-pruning
///    on completion, so ``cancelAll()`` (driven from the view's disappear hook)
///    tears down anything still in flight.
///  - ``coalesce(_:)`` keeps a **single** prefetch task: a new request cancels
///    and replaces the previous one, so rapid input can never stack overlapping
///    passes.
///
/// It is deliberately I/O-free and lives in PoseDeckCore so the cancellation /
/// coalescing contract is exhaustively unit-testable (the swipe UI on top of it
/// is compile-verified only — the simulator can't boot in this env).
@MainActor
public final class ShootTaskScheduler {

    /// Outstanding fire-and-forget persist tasks, keyed by a monotonic token so a
    /// task can prune itself on completion without racing other entries.
    private var persistTasks: [Int: Task<Void, Never>] = [:]
    /// The single in-flight coalesced prefetch task, if any.
    private var prefetchTask: Task<Void, Never>?
    private var nextToken = 0
    /// Set once ``cancelAll()`` runs, so any work scheduled afterwards (e.g. a
    /// late callback firing during teardown) is dropped instead of leaking.
    private(set) public var isCancelled = false

    public init() {}

    /// Number of persist tasks still tracked (in flight + not yet pruned).
    /// Exposed for tests/diagnostics.
    public var pendingPersistCount: Int { persistTasks.count }

    /// `true` while a coalesced prefetch task is retained.
    public var hasPendingPrefetch: Bool { prefetchTask != nil }

    /// Schedule a fire-and-forget persist write. The task is retained until it
    /// finishes (then self-pruned) or until ``cancelAll()`` cancels it. A no-op
    /// once cancelled.
    public func persist(_ work: @escaping @MainActor () async -> Void) {
        guard !isCancelled else { return }
        let token = nextToken
        nextToken += 1
        let task = Task { @MainActor [weak self] in
            // `[GAUNTLET-3]` Honour cancellation BEFORE running the side effect.
            // `Task.cancel()` is cooperative: it only flags a not-yet-started task,
            // it does NOT prevent its body from running. So a `cancelAll()` that
            // raced ahead of this task starting (e.g. `reshoot()` cancelling a
            // queued `markDone`/`markSkipped` persist before its scoped completion
            // reset) would otherwise still fire the write — re-stranding the card
            // as done/skipped *after* the reset wrote pending. The explicit check
            // makes the scheduler's "cancelAll tears down in-flight work" contract
            // actually hold for a write whose body is otherwise suspension-free.
            guard !Task.isCancelled else { self?.persistTasks[token] = nil; return }
            await work()
            self?.persistTasks[token] = nil
        }
        persistTasks[token] = task
    }

    /// Schedule a coalesced prefetch pass: cancels and replaces any previous
    /// prefetch task so rapid swipes don't stack overlapping passes. A no-op once
    /// cancelled.
    public func coalesce(_ work: @escaping @MainActor () async -> Void) {
        guard !isCancelled else { return }
        prefetchTask?.cancel()
        prefetchTask = Task { @MainActor [weak self] in
            await work()
            // Only clear if we're still the current task — a newer coalesce() may
            // have replaced us while we ran.
            guard let self, !Task.isCancelled else { return }
            self.prefetchTask = nil
        }
    }

    /// Cancel every outstanding task and refuse further scheduling. Idempotent;
    /// driven from the shoot view's disappear hook so dismissing the screen tears
    /// down all pending image fetches and completion writes.
    public func cancelAll() {
        isCancelled = true
        prefetchTask?.cancel()
        prefetchTask = nil
        for task in persistTasks.values { task.cancel() }
        persistTasks.removeAll()
    }

    /// Re-arm the scheduler after a prior ``cancelAll()`` so a reused session can
    /// schedule work again. Without this the ``isCancelled`` latch is permanent:
    /// a view model whose view disappears (which calls ``cancelAll()``) and then
    /// reappears on the *same* instance — possible under tab switches or offscreen
    /// lazy rows, where SwiftUI fires `onDisappear` without destroying the view's
    /// `@State` — would silently drop every subsequent persist + prefetch while
    /// the UI keeps mutating the session. Driven from the shoot view model's
    /// `load()`, which runs on every appear. Idempotent and safe to call when not
    /// cancelled. Does not resurrect already-cancelled tasks; only future work.
    public func resume() {
        isCancelled = false
    }
}
