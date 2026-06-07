import Foundation
import SwiftData
import Observation
import PoseDeckCore

/// An `@Observable` counter bumped (debounced) whenever the SwiftData mirror
/// changes, so views that read through the mirror repositories can re-query
/// after a realtime merge / outbox confirmation without each owning a
/// `@Query` (M3 plan, STEP 10).
///
/// **Debounce is required** (250–500ms): a backfill or a burst of realtime
/// events fires many `ModelContext.didSave` notifications in quick succession;
/// bumping the counter on every one would stampede every observing view into a
/// re-query per event. The ticker coalesces a burst into a single bump after the
/// quiet window, so the UI refreshes once.
@MainActor
@Observable
final class MirrorChangeTicker {

    /// Bumped (after debounce) on each batch of mirror changes. Views read this
    /// (e.g. in a `.task(id:)` or by referencing it in `body`) to re-query.
    var revision: Int { coalescer.revision }

    /// Pure coalescing bookkeeping (revision counter + pending flag), lifted into
    /// `PoseDeckCore` so the burst-into-one-bump contract is unit-testable.
    private var coalescer = ChangeTickerCoalescer()

    /// Teardown state (the NotificationCenter observer token + debounce task)
    /// lives in a nonisolated reference so the (nonisolated) `deinit` can tear
    /// it down without touching `@MainActor`-isolated stored properties — which
    /// Swift 6 forbids for non-Sendable state. The token and task are only ever
    /// mutated from the main actor (init + `scheduleBump`), and both
    /// `NotificationCenter.removeObserver` and `Task.cancel` are safe to call
    /// from any thread, so the nonisolated read in `deinit` is race-free.
    private let cleanup = Cleanup()
    @ObservationIgnored private var debounceTask: Task<Void, Never>? {
        get { cleanup.debounceTask }
        set { cleanup.debounceTask = newValue }
    }
    @ObservationIgnored private let debounce: Duration

    /// - Parameter debounceMilliseconds: quiet window before a bump (default 300ms,
    ///   inside the required 250–500ms band).
    init(debounceMilliseconds: Int = 300) {
        self.debounce = .milliseconds(debounceMilliseconds)
        cleanup.observer = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // The notification is delivered on the main queue; hop onto the main
            // actor to schedule the debounced bump.
            MainActor.assumeIsolated {
                self?.coalescer.noteChange()
                self?.scheduleBump()
            }
        }
    }

    deinit {
        // Nonisolated teardown via the shared holder (see `cleanup`).
        cleanup.tearDown()
    }

    /// Nonisolated holder for teardown state so `deinit` can release it without
    /// crossing actor isolation. `@unchecked Sendable`: the stored values are
    /// only mutated on the main actor, and `removeObserver` / `Task.cancel` are
    /// thread-safe, so the deinit-time access cannot race a live mutation.
    private final class Cleanup: @unchecked Sendable {
        var observer: NSObjectProtocol?
        var debounceTask: Task<Void, Never>?

        func tearDown() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            debounceTask?.cancel()
        }
    }

    /// Coalesce a burst of change notifications into a single bump after the
    /// debounce window. A new notification restarts the timer.
    private func scheduleBump() {
        debounceTask?.cancel()
        let delay = debounce
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            // Collapse the whole burst into a single observable bump. The
            // coalescer no-ops if nothing is pending, so a stray timer can't
            // churn observing views.
            self?.coalescer.flush()
        }
    }
}
