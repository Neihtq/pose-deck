import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// File-handling additions to ``APIClient`` for the image pipeline
/// (ARCHITECTURE.md §5). These build on the existing actor (auth token,
/// base URL, request plumbing) rather than reimplementing CRUD.
///
/// Note: the multipart create and the protected-file token endpoint are not part
/// of the generic JSON CRUD surface, so they live here as a focused extension.
public extension APIClient {
    /// A single multipart field: either a plain text value or a file part.
    enum MultipartField: Sendable {
        case text(name: String, value: String)
        case file(name: String, filename: String, mimeType: String, data: Data)
    }

    /// Create a record in `collection` using `multipart/form-data` (for file
    /// uploads). Decodes the created record as `T`.
    func createMultipart<T: Codable & Sendable>(
        collection: String,
        fields: [MultipartField]
    ) async throws -> T {
        let boundary = "PoseDeck-\(UUID().uuidString)"
        let body = Self.encodeMultipart(fields: fields, boundary: boundary)
        let request = try makeFileRequest(
            method: "POST",
            path: "/api/collections/\(collection)/records",
            contentType: "multipart/form-data; boundary=\(boundary)",
            body: body
        )
        return try await sendDecoding(request)
    }

    /// Mint a short-lived file access token for protected file URLs
    /// (`POST /api/files/token`). Protected collections (e.g. `card_images`,
    /// which has a view rule) require this token as a `?token=` query param;
    /// the `Authorization` header alone is not honoured for `GET /api/files/...`.
    func fileToken() async throws -> String {
        struct TokenResponse: Codable, Sendable { let token: String }
        let request = try makeFileRequest(
            method: "POST",
            path: "/api/files/token",
            contentType: nil,
            body: nil
        )
        let response: TokenResponse = try await sendDecoding(request)
        return response.token
    }

    /// Build an absolute file URL for a stored file, optionally carrying a
    /// short-lived access `token` for protected collections
    /// (`/api/files/<collection>/<recordId>/<filename>?token=...`).
    nonisolated func fileURL(
        collection: String,
        recordId: String,
        filename: String,
        token: String? = nil
    ) -> URL? {
        let path = "/api/files/\(collection)/\(recordId)/\(filename)"
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        ) else {
            return nil
        }
        if let token, !token.isEmpty {
            components.queryItems = [URLQueryItem(name: "token", value: token)]
        }
        return components.url
    }

    // MARK: - Internal plumbing

    /// Encode multipart/form-data body bytes for the given fields + boundary.
    /// Pure and `static` so it is unit-testable without the network.
    internal static func encodeMultipart(fields: [MultipartField], boundary: String) -> Data {
        var body = Data()
        let crlf = "\r\n"
        func append(_ string: String) { body.append(Data(string.utf8)) }

        for field in fields {
            append("--\(boundary)\(crlf)")
            switch field {
            case let .text(name, value):
                append("Content-Disposition: form-data; name=\"\(name)\"\(crlf)\(crlf)")
                append("\(value)\(crlf)")
            case let .file(name, filename, mimeType, data):
                append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\(crlf)")
                append("Content-Type: \(mimeType)\(crlf)\(crlf)")
                body.append(data)
                append(crlf)
            }
        }
        append("--\(boundary)--\(crlf)")
        return body
    }

    /// Build an authenticated request with an explicit content type (or none).
    /// Mirrors ``APIClient``'s private `makeRequest` but allows non-JSON bodies.
    private func makeFileRequest(
        method: String,
        path: String,
        contentType: String?,
        body: Data?
    ) throws -> URLRequest {
        guard let url = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )?.url else {
            throw APIClientError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let token = authToken else {
            throw APIClientError.notAuthenticated
        }
        request.setValue(token, forHTTPHeaderField: "Authorization")
        return request
    }

    /// Send a request and decode the JSON response as `T`, surfacing the same
    /// errors as the core client's `send`.
    private func sendDecoding<T: Decodable>(_ request: URLRequest) async throws -> T {
        // Reuse the actor's injected session (via `performRaw`) so file endpoints
        // route through the same stubbed session as the rest of the client in
        // tests, and apply the standard status-code check.
        let data = try await performRaw(request)
        // Use the shared PocketBase decoder so the space-separated datetime
        // format and empty-string-unset case are handled (ARCHITECTURE.md §3).
        return try PocketBaseDate.decode(T.self, from: data)
    }
}
