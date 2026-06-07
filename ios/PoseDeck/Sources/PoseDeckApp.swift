import SwiftUI
import SwiftData
import PoseDeckCore

/// App entry point.
///
/// Constructs the single shared ``APIClient`` (configured from ``AppConfig``),
/// the ``AuthService`` (backed by the real Security-framework ``KeychainStore``
/// so sessions survive relaunch), the SwiftData mirror ``ModelContainer``, and
/// the ``SyncCoordinator`` that owns the offline-first sync lifecycle, then hands
/// them to ``RootView`` which gates between the login screen and the deck list.
@main
struct PoseDeckApp: App {
    /// Shared REST client, configured with the build-time API base URL.
    private let apiClient: APIClient
    /// Shared observable auth/session service.
    @State private var authService: AuthService
    /// The SwiftData mirror container, shared by every read/write path.
    private let modelContainer: ModelContainer
    /// Owns the outbox processor + realtime + pre-cache lifecycle.
    @State private var sync: SyncCoordinator

    init() {
        let client = APIClient(baseURL: AppConfig.apiBaseURL)
        self.apiClient = client
        let keychain = KeychainStore()
        // UI-test hook: `-uitest-reset` clears any persisted session before the
        // app reads it, so an auth/persistence test starts from a clean,
        // signed-out state. No-op in normal runs.
        if ProcessInfo.processInfo.arguments.contains("-uitest-reset") {
            try? keychain.delete(AuthService.Keys.token)
            try? keychain.delete(AuthService.Keys.user)
        }
        // Persist sessions in the real keychain on device.
        self._authService = State(
            initialValue: AuthService(client: client, keychain: keychain)
        )

        // Build the SwiftData mirror. A failure here is unrecoverable (the app
        // can't run without local storage), so trap with a clear message.
        do {
            self.modelContainer = try LocalMirrorStore.makeContainer()
        } catch {
            fatalError("Failed to create the SwiftData mirror container: \(error)")
        }
        self._sync = State(
            initialValue: SyncCoordinator(container: modelContainer, apiClient: client)
        )

        // Register the BGTask handler early (before launch completes), per
        // BGTaskScheduler requirements. The DEBUG assertion inside verifies the
        // identifier is in Info.plist.
        BackgroundRefresh.register()
    }

    var body: some Scene {
        WindowGroup {
            RootView(apiClient: apiClient, authService: authService, sync: sync)
        }
        .modelContainer(modelContainer)
    }
}
