import XCTest
@testable import PoseDeckCore

/// In-memory mock of ``AuthenticatingClient`` for offline auth tests.
private actor MockAuthClient: AuthenticatingClient {
    private(set) var currentToken: String?
    private(set) var signOutCount = 0
    private let result: Result<AuthResponse, Error>

    init(result: Result<AuthResponse, Error>) {
        self.result = result
    }

    @discardableResult
    func authWithPassword(email: String, password: String) async throws -> AuthResponse {
        switch result {
        case let .success(response):
            currentToken = response.token
            return response
        case let .failure(error):
            throw error
        }
    }

    func setAuthToken(_ token: String?) async {
        currentToken = token
    }

    func signOut() async {
        currentToken = nil
        signOutCount += 1
    }
}

private enum FakeAuthError: Error { case invalidCredentials }

@MainActor
final class AuthServiceTests: XCTestCase {

    private func makeUser() -> User {
        User(id: "u_owner", email: "owner@posedeck.test", name: "Owner")
    }

    private func makeResponse(token: String = "jwt-abc") -> AuthResponse {
        AuthResponse(token: token, record: makeUser())
    }

    func testSignInSetsStateAndPersists() async throws {
        let client = MockAuthClient(result: .success(makeResponse(token: "jwt-abc")))
        let keychain = InMemoryKeychainStore()
        let service = AuthService(client: client, keychain: keychain)

        XCTAssertFalse(service.isAuthenticated)

        try await service.signIn(email: "owner@posedeck.test", password: "changeme123")

        XCTAssertTrue(service.isAuthenticated)
        XCTAssertEqual(service.currentUserId, "u_owner")
        XCTAssertEqual(service.currentUser?.email, "owner@posedeck.test")
        // Token + user persisted to the keychain.
        XCTAssertEqual(try keychain.readString(AuthService.Keys.token), "jwt-abc")
        XCTAssertNotNil(try keychain.read(AuthService.Keys.user))
        let token = await client.currentToken
        XCTAssertEqual(token, "jwt-abc")
    }

    func testSignInFailureLeavesSignedOut() async {
        let client = MockAuthClient(result: .failure(FakeAuthError.invalidCredentials))
        let keychain = InMemoryKeychainStore()
        let service = AuthService(client: client, keychain: keychain)

        do {
            try await service.signIn(email: "owner@posedeck.test", password: "wrong")
            XCTFail("Expected sign-in to throw")
        } catch {
            // expected
        }

        XCTAssertFalse(service.isAuthenticated)
        XCTAssertNil(service.currentUser)
        XCTAssertNil(try? keychain.readString(AuthService.Keys.token))
    }

    func testSignOutClearsStateClientAndKeychain() async throws {
        let client = MockAuthClient(result: .success(makeResponse()))
        let keychain = InMemoryKeychainStore()
        let service = AuthService(client: client, keychain: keychain)

        try await service.signIn(email: "owner@posedeck.test", password: "changeme123")
        await service.signOut()

        XCTAssertFalse(service.isAuthenticated)
        XCTAssertNil(service.currentUser)
        XCTAssertNil(try keychain.readString(AuthService.Keys.token))
        XCTAssertNil(try keychain.read(AuthService.Keys.user))
        let token = await client.currentToken
        XCTAssertNil(token)
        let signOuts = await client.signOutCount
        XCTAssertEqual(signOuts, 1)
    }

    func testRestoreRehydratesSessionFromKeychain() async throws {
        // Seed the keychain as if a previous launch had signed in.
        let keychain = InMemoryKeychainStore()
        try keychain.saveString("persisted-jwt", for: AuthService.Keys.token)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try keychain.save(try encoder.encode(makeUser()), for: AuthService.Keys.user)

        let client = MockAuthClient(result: .failure(FakeAuthError.invalidCredentials))
        let service = AuthService(client: client, keychain: keychain)

        XCTAssertFalse(service.isAuthenticated)
        await service.restore()

        XCTAssertTrue(service.isAuthenticated)
        XCTAssertEqual(service.currentUserId, "u_owner")
        let token = await client.currentToken
        XCTAssertEqual(token, "persisted-jwt", "restore() should re-apply the token to the client")
    }

    func testRestoreWithNoPersistedSessionIsNoOp() async {
        let client = MockAuthClient(result: .failure(FakeAuthError.invalidCredentials))
        let service = AuthService(client: client, keychain: InMemoryKeychainStore())

        await service.restore()
        XCTAssertFalse(service.isAuthenticated)
        XCTAssertNil(service.currentUser)
    }

    // SEC-2 regression: a token present in the keychain with no matching user
    // record (an orphaned JWT) must be purged by restore(), not left behind. The
    // token must also never be applied to the client.
    func testRestoreWithTokenButNoUserPurgesOrphanedToken() async throws {
        let keychain = InMemoryKeychainStore()
        try keychain.saveString("orphaned-jwt", for: AuthService.Keys.token)
        // No user record was persisted.

        let client = MockAuthClient(result: .failure(FakeAuthError.invalidCredentials))
        let service = AuthService(client: client, keychain: keychain)

        await service.restore()

        XCTAssertFalse(service.isAuthenticated)
        XCTAssertNil(service.currentUser)
        // The orphaned token is invalidated client-side, not persisted indefinitely.
        XCTAssertNil(try keychain.readString(AuthService.Keys.token))
        XCTAssertNil(try keychain.read(AuthService.Keys.user))
        // And it was never presented to the client.
        let token = await client.currentToken
        XCTAssertNil(token)
    }

    // SEC-2 regression: a token paired with an undecodable user blob must also be
    // purged rather than leaving a dangling token.
    func testRestoreWithUndecodableUserPurgesBothKeys() async throws {
        let keychain = InMemoryKeychainStore()
        try keychain.saveString("orphaned-jwt", for: AuthService.Keys.token)
        try keychain.save(Data("not-a-user".utf8), for: AuthService.Keys.user)

        let client = MockAuthClient(result: .failure(FakeAuthError.invalidCredentials))
        let service = AuthService(client: client, keychain: keychain)

        await service.restore()

        XCTAssertFalse(service.isAuthenticated)
        XCTAssertNil(try keychain.readString(AuthService.Keys.token))
        XCTAssertNil(try keychain.read(AuthService.Keys.user))
        let token = await client.currentToken
        XCTAssertNil(token)
    }

    // SEC-2 regression: signIn writes token + user atomically. If the user record
    // cannot be persisted, the token must not be left orphaned in the keychain.
    func testSignInRollsBackTokenWhenUserPersistFails() async {
        let keychain = FailOnUserSaveKeychain()
        let client = MockAuthClient(result: .success(makeResponse(token: "jwt-abc")))
        let service = AuthService(client: client, keychain: keychain)

        do {
            try await service.signIn(email: "owner@posedeck.test", password: "changeme123")
            XCTFail("Expected sign-in to throw when the user record cannot be persisted")
        } catch {
            // expected
        }

        // No orphaned token left behind.
        XCTAssertNil(try? keychain.readString(AuthService.Keys.token))
        XCTAssertNil(try? keychain.read(AuthService.Keys.user))
        XCTAssertFalse(service.isAuthenticated)
        XCTAssertNil(service.currentUser)
    }
}

/// A keychain fake that fails when persisting the user record, used to exercise
/// the SEC-2 atomic-write rollback path in `signIn`.
private final class FailOnUserSaveKeychain: KeychainStoring, @unchecked Sendable {
    private let inner = InMemoryKeychainStore()

    func save(_ data: Data, for key: String) throws {
        if key == AuthService.Keys.user {
            throw KeychainError.unexpectedStatus(-1)
        }
        try inner.save(data, for: key)
    }

    func read(_ key: String) throws -> Data? { try inner.read(key) }
    func delete(_ key: String) throws { try inner.delete(key) }
}
