import SwiftUI
import SwiftData
import PoseDeckCore

/// App entry point.
///
/// Builds the SwiftData mirror ``ModelContainer`` and the ``AppEnvironment`` —
/// the composition root that owns the API stack (``APIClient`` / ``AuthService``
/// / ``SyncCoordinator``, configured from ``AppConfig``), the appearance
/// preference (item 3), and the rebuildable backend URL (item 4) — then hands it
/// to ``RootView`` which gates between the login screen and the deck list and
/// applies the selected color scheme.
@main
struct PoseDeckApp: App {
    /// The SwiftData mirror container, shared by every read/write path.
    private let modelContainer: ModelContainer
    /// Composition root + observable app state.
    @State private var env: AppEnvironment

    init() {
        // Build the SwiftData mirror. A failure here is unrecoverable (the app
        // can't run without local storage), so trap with a clear message.
        let container: ModelContainer
        do {
            container = try LocalMirrorStore.makeContainer()
        } catch {
            fatalError("Failed to create the SwiftData mirror container: \(error)")
        }
        self.modelContainer = container

        // Persist sessions in the real keychain on device.
        let environment = AppEnvironment(modelContainer: container, keychain: KeychainStore())
        // UI-test hook: `-uitest-reset` clears any persisted session before the
        // app reads it, so an auth/persistence test starts from a clean,
        // signed-out state. No-op in normal runs.
        if ProcessInfo.processInfo.arguments.contains("-uitest-reset") {
            environment.clearPersistedSessionForUITests()
        }
        self._env = State(initialValue: environment)

        // Register the BGTask handler early (before launch completes), per
        // BGTaskScheduler requirements. The DEBUG assertion inside verifies the
        // identifier is in Info.plist.
        BackgroundRefresh.register()
    }

    var body: some Scene {
        WindowGroup {
            RootView(env: env)
                .preferredColorScheme(env.theme.colorScheme)
        }
        .modelContainer(modelContainer)
    }
}
