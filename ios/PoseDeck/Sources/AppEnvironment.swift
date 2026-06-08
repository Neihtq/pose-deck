import Foundation
import SwiftData
import SwiftUI
import PoseDeckCore

/// The user-selectable appearance (item 3). `system` follows the device setting.
enum AppTheme: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    var id: String { rawValue }

    /// Human label for the picker.
    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var symbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }

    /// The `preferredColorScheme` value to apply at the app root — `nil` for
    /// `system`, which lets SwiftUI follow the device appearance.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// App-wide composition root and source of truth (`@Observable`), held once in
/// `PoseDeckApp` and read by `RootView`.
///
/// Owns the API stack — ``APIClient``, ``AuthService``, ``SyncCoordinator`` —
/// plus the user's appearance + backend-URL preferences. The stack is keyed on
/// the backend URL and can be **rebuilt** when the user enters a different
/// server at login (item 4); because the URL only changes pre-auth (no sync is
/// running yet) the rebuild is safe. `currentUser` is published *here* (synced
/// from the internal auth service after each operation) so views observe a
/// stable object whose identity survives a stack rebuild.
@MainActor
@Observable
final class AppEnvironment: AuthSession {
    /// The SwiftData mirror container — local storage, never rebuilt.
    let modelContainer: ModelContainer

    /// Current API stack. `private(set)` so views read but only ``rebuildStack``
    /// swaps them.
    private(set) var apiClient: APIClient
    private(set) var sync: SyncCoordinator

    /// The internal session service the façade delegates to. Swapped on rebuild.
    private var authService: AuthService

    /// Published authenticated user — the truth `RootView` gates on. Kept in sync
    /// from `authService` after sign-in / sign-out / restore, and reset on a
    /// stack rebuild, so observation fires even though `authService` itself is
    /// swapped out from under it.
    private(set) var currentUser: User?

    /// The backend URL the current stack is built against (drives login prefill).
    private(set) var baseURLString: String

    /// Selected appearance, persisted to `UserDefaults` and applied at the root.
    var theme: AppTheme {
        didSet {
            guard theme != oldValue else { return }
            UserDefaults.standard.set(theme.rawValue, forKey: Self.themeKey)
        }
    }

    private let keychain: KeychainStoring
    private static let themeKey = "posedeck.theme"

    init(modelContainer: ModelContainer, keychain: KeychainStoring) {
        self.modelContainer = modelContainer
        self.keychain = keychain
        self.theme = UserDefaults.standard.string(forKey: Self.themeKey)
            .flatMap(AppTheme.init(rawValue:)) ?? .system

        let urlString = AppConfig.apiBaseURLString
        self.baseURLString = urlString
        let url = URL(string: urlString) ?? AppConfig.apiBaseURL
        let client = APIClient(baseURL: url)
        self.apiClient = client
        self.authService = AuthService(client: client, keychain: keychain)
        self.sync = SyncCoordinator(container: modelContainer, apiClient: client)
        self.currentUser = nil
    }

    // MARK: - Backend URL (item 4)

    /// Point the app at a different backend (entered at login). Persists the
    /// override and rebuilds the API stack against it. A no-op if the URL is
    /// unchanged or unparseable. Safe only while signed out — the caller (the
    /// login flow) guarantees this, and the new stack starts signed-out.
    func applyBackendURL(_ urlString: String) {
        let trimmed = urlString.trimmingCharacters(in: .whitespaces)
        // Clearing the field (empty) reverts to the build-time/default URL.
        AppConfig.setStoredBaseURLString(trimmed)
        let resolved = AppConfig.apiBaseURLString
        guard resolved != baseURLString, URL(string: resolved) != nil else {
            // Keep the stored value (so a no-change re-submit is harmless) but
            // don't churn the stack if the effective URL didn't actually move.
            baseURLString = resolved
            return
        }
        rebuildStack(baseURLString: resolved)
    }

    private func rebuildStack(baseURLString: String) {
        guard let url = URL(string: baseURLString) else { return }
        self.baseURLString = baseURLString
        let client = APIClient(baseURL: url)
        self.apiClient = client
        self.authService = AuthService(client: client, keychain: keychain)
        self.sync = SyncCoordinator(container: modelContainer, apiClient: client)
        self.currentUser = nil
    }

    /// Clear any persisted session before the stack reads it — the `-uitest-reset`
    /// launch hook. Mirrors the prior in-`PoseDeckApp` behavior.
    func clearPersistedSessionForUITests() {
        try? keychain.delete(AuthService.Keys.token)
        try? keychain.delete(AuthService.Keys.user)
    }

    // MARK: - AuthSession façade

    func signIn(email: String, password: String) async throws {
        try await authService.signIn(email: email, password: password)
        currentUser = authService.currentUser
    }

    func signOut() async {
        await authService.signOut()
        currentUser = authService.currentUser
    }

    func restore() async {
        await authService.restore()
        currentUser = authService.currentUser
    }
}
