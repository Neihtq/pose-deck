import SwiftUI
import PoseDeckCore

/// App entry point.
///
/// Constructs the single shared ``APIClient`` (configured from ``AppConfig``) and
/// the ``AuthService`` (backed by the real Security-framework ``KeychainStore``
/// so sessions survive relaunch), then hands both to ``RootView`` which gates
/// between the login screen and the deck list.
@main
struct PoseDeckApp: App {
    /// Shared REST client, configured with the build-time API base URL.
    private let apiClient: APIClient
    /// Shared observable auth/session service.
    @State private var authService: AuthService

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
    }

    var body: some Scene {
        WindowGroup {
            RootView(apiClient: apiClient, authService: authService)
        }
    }
}
