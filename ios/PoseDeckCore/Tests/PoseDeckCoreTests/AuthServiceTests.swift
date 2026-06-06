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
}
