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
    ///
    /// `nonisolated` because it is an immutable value set at init; the app's
    /// realtime wiring reads it synchronously to build its own SSE transport.
    public nonisolated let baseURL: URL
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// Current JWT auth token, set after a successful ``authWithPassword(email:password:)``.
    private(set) var authToken: String?

    /// - Parameters:
    ///   - baseURL: PocketBase base URL.
    ///   - session: URLSession used for all requests.
    ///   - encoder: JSON encoder for request bodies. Defaults to a
    ///     PocketBase-configured encoder (datetimes in PocketBase wire format).
    ///   - decoder: JSON decoder for response bodies. Defaults to a
    ///     PocketBase-configured decoder. Note: PocketBase serializes datetimes
    ///     as `"yyyy-MM-dd HH:mm:ss.SSSZ"` (space separator, not `.iso8601`),
    ///     and represents unset datetimes as `""`; ``send(_:)`` sanitizes
    ///     empty-string datetime values to `null` before decoding so optional
    ///     `Date?` fields decode to `nil`.
    public init(
        baseURL: URL,
        session: URLSession = .shared,
        encoder: JSONEncoder = PocketBaseDate.makeEncoder(),
        decoder: JSONDecoder = PocketBaseDate.makeDecoder()
    ) {
        self.baseURL = baseURL
        self.session = session
        self.encoder = encoder
        self.decoder = decoder
    }

    /// Manually set or clear the auth token (e.g. when restoring a persisted session).
    public func setAuthToken(_ token: String?) {
        self.authToken = token
    }

    /// The current bearer token, if any. Exposed so the app's realtime wiring
    /// (which opens its own SSE transport) can authenticate with the same token
    /// the REST client holds, without the app duplicating session state.
    public func currentAuthToken() -> String? { authToken }

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

    /// List *every* matching record across all pages, mirroring the web SDK's
    /// `getFullList`.
    ///
    /// A single ``list(_:collection:page:perPage:filter:sort:)`` call returns at
    /// most one page, so callers that must process the full result set (e.g.
    /// duplicating a deck's cards) would silently drop anything beyond the first
    /// page. This walks pages `1..totalPages`, accumulating items, so no records
    /// are lost regardless of count.
    ///
    /// - Parameter perPage: page size used for each underlying request (larger
    ///   pages mean fewer round-trips). Defaults to 200 to match the existing
    ///   single-page call sites.
    public func listAll<T: Codable & Sendable>(
        _ type: T.Type = T.self,
        collection: String,
        perPage: Int = 200,
        filter: String? = nil,
        sort: String? = nil
    ) async throws -> [T] {
        var items: [T] = []
        var page = 1
        while true {
            let response = try await list(
                T.self,
                collection: collection,
                page: page,
                perPage: perPage,
                filter: filter,
                sort: sort
            )
            items.append(contentsOf: response.items)
            // Stop once we've fetched the last reported page, or defensively if a
            // page comes back empty (guards against a 0/short totalPages).
            if page >= response.totalPages || response.items.isEmpty {
                break
            }
            page += 1
        }
        return items
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

    // MARK: - Realtime (SSE)

    /// Subscribe to one collection's realtime stream and forward decoded record
    /// events to `onEvent` (ARCHITECTURE.md §4.4).
    ///
    /// Thin delegation to ``RealtimeClient`` over a ``URLSessionSSETransport``
    /// built from this client's `baseURL` and current auth token: it performs
    /// the PB handshake (`GET /api/realtime` → `PB_CONNECT` → `POST` the
    /// subscription), parses the SSE stream, and reconnects/resubscribes on a
    /// drop. The returned ``RealtimeClient`` is the connection handle — call
    /// `stop()` on it to disconnect.
    ///
    /// For the full five-collection app subscription, construct a
    /// ``RealtimeClient`` directly with the default `subscriptions`; this
    /// single-collection helper exists for focused callers and tests.
    @discardableResult
    public func subscribe(
        collection: String,
        onEvent: @escaping @Sendable (RealtimeClient.RecordEvent) async -> Void
    ) async -> RealtimeClient {
        let transport = URLSessionSSETransport(baseURL: baseURL, session: session)
        let client = RealtimeClient(
            transport: transport,
            subscriptions: [collection],
            authToken: authToken,
            onEvent: onEvent
        )
        Task { await client.run() }
        return client
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
        try await performRaw(request)
    }

    /// Dispatch a raw outbox mutation: send `body` verbatim to `path` with the
    /// given HTTP `method`, attaching the `X-Idempotency-Key` header.
    ///
    /// The body is the already-encoded PocketBase record JSON owned by the
    /// outbox entry — it is NOT re-encoded here, so the client-supplied `id` and
    /// wire-format datetimes are preserved exactly. On a non-2xx response this
    /// throws ``APIClientError/httpError(status:body:)`` so ``MutationSender``
    /// can classify the status (incl. the 400 duplicate-id idempotent replay).
    ///
    /// Used by the M3 outbox processor; routes through the same injected
    /// `URLSession` so it is exercised offline via `StubURLProtocol` in tests.
    func performMutation(
        method: String,
        path: String,
        body: Data?,
        idempotencyKey: UUID
    ) async throws -> Data {
        var request = try makeRequest(method: method, path: path, body: body)
        // Forward-compat idempotency header (invariant #1 relies on the
        // client-supplied id, not this header, but we send it regardless).
        request.setValue(idempotencyKey.uuidString, forHTTPHeaderField: "X-Idempotency-Key")
        return try await performRaw(request)
    }

    /// Send a prepared request through the client's own `URLSession`, applying
    /// the standard HTTP status-code check, and return the raw body.
    ///
    /// Exposed `internal` so focused extensions (e.g. the file/image endpoints in
    /// `APIClient+Files`) reuse the injected session — important so they route
    /// through the same stubbed session in tests rather than `URLSession.shared`.
    func performRaw(_ request: URLRequest) async throws -> Data {
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
        // PocketBase encodes unset datetimes as "". A custom date-decoding
        // strategy cannot map a present empty string to nil for optional Date?
        // fields, so sanitize empty-string datetime values to JSON null first.
        let sanitized = (try? PocketBaseDate.sanitizeEmptyDatetimes(in: data)) ?? data
        return try decoder.decode(T.self, from: sanitized)
    }
}
