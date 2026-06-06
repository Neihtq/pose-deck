import Foundation
#if canImport(Observation)
import Observation
#endif

/// The subset of ``APIClient`` behaviour ``AuthService`` depends on.
///
/// Exposed as a protocol so a fake can drive sign-in/out state in tests and
/// previews without touching the network. ``APIClient`` conforms via an
/// extension below.
public protocol AuthenticatingClient: Sendable {
    /// Authenticate with email + password; on success the token is applied to
    /// the client and the auth record is returned.
    @discardableResult
    func authWithPassword(email: String, password: String) async throws -> AuthResponse
    /// Set or clear the bearer token used for subsequent requests (used to
    /// restore a persisted session on launch).
    func setAuthToken(_ token: String?) async
    /// Drop the current auth token.
    func signOut() async
}

extension APIClient: AuthenticatingClient {}

/// Abstraction over the session service so views/tests can use a fake.
///
/// Conformers are `@MainActor` `@Observable` so SwiftUI can observe
/// `currentUser` / `isAuthenticated` directly.
@MainActor
public protocol AuthSession: AnyObject {
    /// The authenticated user, or `nil` when signed out.
    var currentUser: User? { get }
    /// Convenience: the authenticated user's id, or `nil`.
    var currentUserId: String? { get }
    /// Whether there is an active authenticated session.
    var isAuthenticated: Bool { get }

    /// Authenticate and persist the session (token + user) to the keychain.
    func signIn(email: String, password: String) async throws
    /// Clear in-memory and persisted session state and drop the client token.
    func signOut() async
    /// Restore a persisted session (token + user) from the keychain, if present.
    func restore() async
}

public extension AuthSession {
    var currentUserId: String? { currentUser?.id }
    var isAuthenticated: Bool { currentUser != nil }
}

/// Observable email+password session service over an ``AuthenticatingClient``.
///
/// Persists the JWT and the authenticated ``User`` record in the keychain
/// (``KeychainStoring``) so sessions survive relaunch, restoring on ``restore()``
/// (call from app launch). UI limits and product rules live elsewhere; this type
/// owns only auth/session state.
@MainActor
@Observable
public final class AuthService: AuthSession {
    /// Keychain keys used by this service.
    public enum Keys {
        public static let token = "posedeck.auth.token"
        public static let user = "posedeck.auth.user"
    }

    public private(set) var currentUser: User?

    private let client: AuthenticatingClient
    private let keychain: KeychainStoring
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// - Parameters:
    ///   - client: the API client to authenticate through.
    ///   - keychain: secret store for the persisted token + user (defaults to
    ///     the in-memory fake so non-Apple test hosts work; the app injects the
    ///     real `KeychainStore`).
    public init(
        client: AuthenticatingClient,
        keychain: KeychainStoring = InMemoryKeychainStore()
    ) {
        self.client = client
        self.keychain = keychain
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    public func signIn(email: String, password: String) async throws {
        let response = try await client.authWithPassword(email: email, password: password)
        // Persist before publishing state so a crash mid-flight can't leave an
        // observable session with nothing in the keychain.
        try keychain.saveString(response.token, for: Keys.token)
        if let userData = try? encoder.encode(response.record) {
            try keychain.save(userData, for: Keys.user)
        }
        currentUser = response.record
    }

    public func signOut() async {
        await client.signOut()
        try? keychain.delete(Keys.token)
        try? keychain.delete(Keys.user)
        currentUser = nil
    }

    public func restore() async {
        guard
            let token = try? keychain.readString(Keys.token),
            !token.isEmpty,
            let userData = try? keychain.read(Keys.user),
            let user = try? decoder.decode(User.self, from: userData)
        else {
            return
        }
        await client.setAuthToken(token)
        currentUser = user
    }
}
