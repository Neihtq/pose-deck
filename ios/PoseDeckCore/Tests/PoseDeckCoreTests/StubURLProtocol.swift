import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A `URLProtocol` stub that serves canned responses to requests, recording each
/// request it sees. Lets `APIClient` be exercised fully offline.
///
/// Register a handler that maps a `URLRequest` to a `(status, body)` pair, then
/// build a `URLSession` via ``makeSession()``. Inspect ``recordedRequests`` and
/// ``recordedBodies`` after the call to assert on method/path/query/payload.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {

    /// Box holding the shared handler + recorded traffic, guarded by a lock so
    /// it is safe to mutate from the protocol's loading thread and read from the
    /// test thread.
    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var _handler: (@Sendable (URLRequest) -> (Int, Data))?
        private var _requests: [URLRequest] = []
        private var _bodies: [Data] = []

        func setHandler(_ handler: @escaping @Sendable (URLRequest) -> (Int, Data)) {
            lock.lock(); defer { lock.unlock() }
            _handler = handler
        }

        func record(_ request: URLRequest, body: Data) -> (Int, Data) {
            lock.lock(); defer { lock.unlock() }
            _requests.append(request)
            _bodies.append(body)
            return _handler?(request) ?? (200, Data("{}".utf8))
        }

        var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return _requests }
        var bodies: [Data] { lock.lock(); defer { lock.unlock() }; return _bodies }
        func reset() {
            lock.lock(); defer { lock.unlock() }
            _handler = nil; _requests = []; _bodies = []
        }
    }

    static let shared = State()

    /// Build a `URLSession` that routes all traffic through this stub.
    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // URLProtocol strips httpBody for some methods; recover it from the
        // body stream when needed so create/update payloads can be asserted.
        let body = Self.bodyData(from: request)
        let (status, data) = Self.shared.record(request, body: body)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func bodyData(from request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
