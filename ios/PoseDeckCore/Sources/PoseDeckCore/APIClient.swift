import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Errors surfaced by ``APIClient``.
public enum APIClientError: Error, Sendable {
    /// The configured base URL could not be combined with the request path.
    case invalidURL
    /// The response was not an `HTTPURLResponse`.
    case nonHTTPResponse
    /// The server returned a non-2xx status code. Carries the status and raw body.
    case httpError(status: Int, body: Data)
    /// A request requiring authentication was attempted with no auth token set.
    case notAuthenticated
}

/// Minimal PocketBase auth response shape for the password auth endpoint.
public struct AuthResponse: Codable, Sendable {
    /// JWT auth token to send on subsequent requests.
    public let token: String
    /// The authenticated user record.
    public let record: User
}

/// PocketBase list response envelope for `getList`-style endpoints.
public struct ListResponse<T: Codable & Sendable>: Codable, Sendable {
    public let page: Int
    public let perPage: Int
    public let totalItems: Int
    public let totalPages: Int
    public let items: [T]

    enum CodingKeys: String, CodingKey {
        case page
        case perPage
        case totalItems
        case totalPages
        case items
    }
}

/// Async/await REST client skeleton for the PocketBase backend.
///
/// Covers password auth and generic list/create/update/delete against any
/// collection. Built on `URLSession`. Realtime (SSE) is a documented TODO stub
/// — see ``subscribe(collection:)``.
///
/// Concurrency: the auth token is held behind an actor so the client is
/// `Sendable` and safe to share across tasks.
public actor APIClient {
    /// Base URL of the PocketBase instance, e.g. `http://localhost:8090`.
    public let baseURL: URL
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// Current JWT auth token, set after a successful ``authWithPassword(email:password:)``.
    private(set) var authToken: String?

    public init(
        baseURL: URL,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.session = session

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    /// Manually set or clear the auth token (e.g. when restoring a persisted session).
    public func setAuthToken(_ token: String?) {
        self.authToken = token
    }

    // MARK: - Auth

    /// Authenticate against the `users` collection with email + password.
    ///
    /// On success the returned token is stored and applied to subsequent requests.
    @discardableResult
    public func authWithPassword(email: String, password: String) async throws -> AuthResponse {
        let body: [String: String] = ["identity": email, "password": password]
        let payload = try JSONSerialization.data(withJSONObject: body)
        let request = try makeRequest(
            method: "POST",
            path: "/api/collections/users/auth-with-password",
            body: payload,
            requiresAuth: false
        )
        let response: AuthResponse = try await send(request)
        self.authToken = response.token
        return response
    }

    /// Drop the current auth token.
    public func signOut() {
        self.authToken = nil
    }

    // MARK: - Generic CRUD

    /// List records from a collection.
    ///
    /// - Parameters:
    ///   - collection: PocketBase collection name (e.g. `"decks"`).
    ///   - page: 1-based page index.
    ///   - perPage: page size.
    ///   - filter: optional PocketBase filter expression.
    ///   - sort: optional sort expression (e.g. `"-created"`).
    public func list<T: Codable & Sendable>(
        _ type: T.Type = T.self,
        collection: String,
        page: Int = 1,
        perPage: Int = 50,
        filter: String? = nil,
        sort: String? = nil
    ) async throws -> ListResponse<T> {
        var query: [URLQueryItem] = [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "perPage", value: String(perPage)),
        ]
        if let filter { query.append(URLQueryItem(name: "filter", value: filter)) }
        if let sort { query.append(URLQueryItem(name: "sort", value: sort)) }

        let request = try makeRequest(
            method: "GET",
            path: "/api/collections/\(collection)/records",
            query: query
        )
        return try await send(request)
    }

    /// Create a record in a collection.
    public func create<Body: Encodable & Sendable, T: Codable & Sendable>(
        collection: String,
        body: Body
    ) async throws -> T {
        let payload = try encoder.encode(body)
        let request = try makeRequest(
            method: "POST",
            path: "/api/collections/\(collection)/records",
            body: payload
        )
        return try await send(request)
    }

    /// Update a record in a collection by id (PATCH — partial update).
    public func update<Body: Encodable & Sendable, T: Codable & Sendable>(
        collection: String,
        id: String,
        body: Body
    ) async throws -> T {
        let payload = try encoder.encode(body)
        let request = try makeRequest(
            method: "PATCH",
            path: "/api/collections/\(collection)/records/\(id)",
            body: payload
        )
        return try await send(request)
    }

    /// Delete a record from a collection by id.
    public func delete(collection: String, id: String) async throws {
        let request = try makeRequest(
            method: "DELETE",
            path: "/api/collections/\(collection)/records/\(id)"
        )
        _ = try await sendRaw(request)
    }

    // MARK: - Realtime (TODO stub)

    /// TODO: Realtime subscription via PocketBase's SSE endpoint
    /// (`GET /api/realtime`). Per ARCHITECTURE.md §4.4 the client should, on
    /// login, open an SSE connection, POST the desired collection subscriptions
    /// to `/api/realtime`, and feed incoming events through the last-write-wins
    /// merge (§4.3). The server filters events using collection rules so the
    /// client only receives records it can see.
    ///
    /// Not implemented in this skeleton — `URLSession` SSE handling, reconnect
    /// with backoff, and the event-decoding pipeline land with the M3 sync work.
    public func subscribe(collection: String) async throws {
        // Intentionally unimplemented: documented stub for the M3 realtime layer.
        fatalError("Realtime subscription not implemented yet (see ARCHITECTURE.md §4.4).")
    }

    // MARK: - Request plumbing

    private func makeRequest(
        method: String,
        path: String,
        query: [URLQueryItem] = [],
        body: Data? = nil,
        requiresAuth: Bool = true
    ) throws -> URLRequest {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        ) else {
            throw APIClientError.invalidURL
        }
        if !query.isEmpty {
            components.queryItems = query
        }
        guard let url = components.url else {
            throw APIClientError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if requiresAuth {
            guard let authToken else {
                throw APIClientError.notAuthenticated
            }
            request.setValue(authToken, forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func sendRaw(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIClientError.nonHTTPResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw APIClientError.httpError(status: http.statusCode, body: data)
        }
        return data
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let data = try await sendRaw(request)
        return try decoder.decode(T.self, from: data)
    }
}
