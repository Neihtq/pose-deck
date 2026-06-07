import Foundation
import SwiftData
import Observation

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
    private(set) var revision = 0

    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private let debounce: Duration

    /// - Parameter debounceMilliseconds: quiet window before a bump (default 300ms,
    ///   inside the required 250–500ms band).
    init(debounceMilliseconds: Int = 300) {
        self.debounce = .milliseconds(debounceMilliseconds)
        observer = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // The notification is delivered on the main queue; hop onto the main
            // actor to schedule the debounced bump.
            MainActor.assumeIsolated {
                self?.scheduleBump()
            }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        debounceTask?.cancel()
    }

    /// Coalesce a burst of change notifications into a single bump after the
    /// debounce window. A new notification restarts the timer.
    private func scheduleBump() {
        debounceTask?.cancel()
        let delay = debounce
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.revision &+= 1
        }
    }
}
