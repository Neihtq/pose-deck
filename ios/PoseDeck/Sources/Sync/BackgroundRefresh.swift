import Foundation
import BackgroundTasks
import PoseDeckCore

/// Registers and schedules the background pre-cache task (M3 plan, STEP 10).
///
/// The task identifier is a **single shared constant** (``taskIdentifier``) used
/// for both the `Info.plist` `BGTaskSchedulerPermittedIdentifiers` entry and the
/// `register`/`schedule`/submit calls — a mismatch between those is the classic
/// `BGTaskScheduler` crash, so a DEBUG assertion verifies the identifier is
/// actually present in the bundle's permitted list at registration time.
///
/// Device-only: the registration/scheduling/handler glue compiles and is wired
/// here, but `BGAppRefreshTask` firing can only be exercised on a device (out of
/// scope for the CI compile-check).
enum BackgroundRefresh {

    /// The single shared task identifier. MUST match the `project.yml`
    /// `BGTaskSchedulerPermittedIdentifiers` entry exactly.
    static let taskIdentifier = "dev.posedeck.app.precache"

    /// Builds the ``PrecacheService`` + targets for a fired task. Injected by the
    /// app at launch so this enum stays free of the live API client / container.
    @MainActor static var precacheProvider: (() async -> (service: PrecacheService, targets: [String], nextRefresh: Date)?)?

    /// Register the launch handler. Call once, early, in the app's `init`
    /// (before the app finishes launching) — registering later traps.
    static func register() {
        assertIdentifierPermitted()
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: taskIdentifier,
            using: nil
        ) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            // BGTaskScheduler invokes this launch handler on the main thread, so
            // `refreshTask` is already main-actor-confined in practice — but its
            // type (`BGAppRefreshTask`) is non-Sendable, so the compiler can't
            // know that as it crosses from this nonisolated @Sendable closure to
            // the @MainActor `handle`. The box carries the OS's main-thread
            // guarantee across that boundary; `assumeIsolated` then asserts it.
            let box = UncheckedSendableBox(refreshTask)
            MainActor.assumeIsolated { handle(box.value) }
        }
    }

    /// Submit a refresh request for `earliestBeginDate` (computed via
    /// ``PrecachePlan/nextRefreshDate(decks:now:minInterval:defaultInterval:)``).
    static func schedule(earliestBeginDate: Date) {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = earliestBeginDate
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Scheduling can fail in the simulator / when disabled; non-fatal.
            #if DEBUG
            print("[BackgroundRefresh] submit failed: \(error)")
            #endif
        }
    }

    /// Handle a fired refresh task: compute targets, run the pre-cache under the
    /// task's expiration deadline, reschedule the next run, and report completion.
    @MainActor
    private static func handle(_ task: BGAppRefreshTask) {
        // `task` is confined to the main actor for its whole lifetime here, so
        // `setTaskCompleted` and the `expirationHandler` assignment never race:
        // both `handle` and the work closure are main-actor-isolated, and the
        // expiration handler only touches the Sendable `work` Task. Without this
        // isolation `task` (a non-Sendable `BGAppRefreshTask`) would be *sent*
        // from the nonisolated register-handler context into a main-actor work
        // closure while still being used nonisolated to set `expirationHandler`
        // — the exact cross-actor send Swift 6 strict concurrency rejects.
        let work = Task { @MainActor in
            guard let provider = precacheProvider, let plan = await provider() else {
                task.setTaskCompleted(success: false)
                return
            }
            // The OS gives a few seconds of headroom; cap our deadline well under it.
            let deadline = Date().addingTimeInterval(25)
            _ = await plan.service.precache(targets: plan.targets, deadline: deadline)
            schedule(earliestBeginDate: plan.nextRefresh)
            task.setTaskCompleted(success: true)
        }
        // Expiration: cancel the work so the OS doesn't kill us mid-write. The
        // closure captures only the Sendable `work` handle, not `task`.
        task.expirationHandler = { work.cancel() }
    }

    /// DEBUG-only guard: the task identifier must be listed in the bundle's
    /// `BGTaskSchedulerPermittedIdentifiers`, or `register` would trap at runtime.
    private static func assertIdentifierPermitted() {
        #if DEBUG
        let permitted = Bundle.main.object(
            forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers"
        ) as? [String] ?? []
        assert(
            permitted.contains(taskIdentifier),
            "BGTaskSchedulerPermittedIdentifiers must contain \(taskIdentifier) — add it to project.yml Info.plist"
        )
        #endif
    }
}

/// Carries a non-Sendable value across an isolation boundary where a runtime
/// invariant (here: BGTaskScheduler always invokes its launch handler on the
/// main thread) guarantees there is no concurrent access. Use only with such a
/// guarantee, immediately re-entering the value's home isolation (e.g. via
/// `MainActor.assumeIsolated`) on the other side.
private struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
