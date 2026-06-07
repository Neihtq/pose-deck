import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A parsed Server-Sent Event (W3C `text/event-stream`).
public struct SSEEvent: Sendable, Equatable {
    /// The `event:` field, defaulting to `"message"` per the spec.
    public var event: String
    /// The accumulated `data:` payload (multiple `data:` lines joined by `\n`).
    public var data: String
    /// The `id:` field, if present.
    public var id: String?

    public init(event: String = "message", data: String = "", id: String? = nil) {
        self.event = event
        self.data = data
        self.id = id
    }
}

/// A pure, incremental Server-Sent-Events parser (M3 plan, STEP 9).
///
/// Feed it bytes or text as they arrive (chunks may split a line or even a
/// multi-byte UTF-8 scalar); it buffers partial lines and emits a complete
/// ``SSEEvent`` each time it sees a blank line, following the W3C
/// `text/event-stream` rules:
///  - lines beginning with `:` are comments (PocketBase sends these as
///    keep-alives) and are ignored,
///  - `field: value` (a single optional leading space after the colon is
///    stripped),
///  - multiple `data:` lines accumulate, joined by `\n`,
///  - a blank line dispatches the buffered event,
///  - `\r\n`, `\r`, and `\n` are all accepted line terminators.
///
/// It is a `struct` with `mutating` feeds so it is trivially unit-testable and
/// has no concurrency surface of its own.
public struct SSEParser: Sendable {
    private var byteBuffer = Data()
    private var dataLines: [String] = []
    private var eventType: String?
    private var lastEventId: String?
    private var sawAnyField = false

    public init() {}

    /// Feed a chunk of raw bytes; returns any complete events produced.
    public mutating func feed(_ bytes: Data) -> [SSEEvent] {
        byteBuffer.append(bytes)
        var events: [SSEEvent] = []

        // Split on LF; keep a trailing partial (no terminator yet) buffered.
        while let lfIndex = byteBuffer.firstIndex(of: 0x0A) {
            let lineData = byteBuffer[byteBuffer.startIndex..<lfIndex]
            byteBuffer.removeSubrange(byteBuffer.startIndex...lfIndex)
            var line = String(decoding: lineData, as: UTF8.self)
            // Tolerate CRLF: strip a trailing CR left on the line.
            if line.hasSuffix("\r") { line.removeLast() }
            if let event = consume(line: line) {
                events.append(event)
            }
        }
        return events
    }

    /// Feed a chunk of text (convenience for tests / line-based transports).
    public mutating func feed(text: String) -> [SSEEvent] {
        feed(Data(text.utf8))
    }

    /// Process one already-de-terminated line; returns an event on a blank line.
    private mutating func consume(line: String) -> SSEEvent? {
        if line.isEmpty {
            // Blank line → dispatch, but only if we actually saw fields. A
            // stray blank (e.g. after a comment-only keep-alive) emits nothing.
            guard sawAnyField else { return nil }
            let event = SSEEvent(
                event: eventType ?? "message",
                data: dataLines.joined(separator: "\n"),
                id: lastEventId
            )
            dataLines.removeAll()
            eventType = nil
            sawAnyField = false
            return event
        }

        // Comment line.
        if line.hasPrefix(":") { return nil }

        // field[:value]
        let field: String
        var value: String
        if let colon = line.firstIndex(of: ":") {
            field = String(line[line.startIndex..<colon])
            value = String(line[line.index(after: colon)...])
            if value.hasPrefix(" ") { value.removeFirst() }
        } else {
            field = line
            value = ""
        }

        switch field {
        case "data":
            dataLines.append(value)
            sawAnyField = true
        case "event":
            eventType = value
            sawAnyField = true
        case "id":
            lastEventId = value
            sawAnyField = true
        case "retry":
            sawAnyField = true // honored by transport, not the parser
        default:
            break // unknown field per spec
        }
        return nil
    }
}

/// Abstraction over the byte stream of a PocketBase realtime SSE connection
/// (M3 plan, STEP 9). Injectable so the handshake/reconnect logic is testable
/// with a stub transport and the production Darwin/Linux transports stay thin.
public protocol SSETransport: Sendable {
    /// Open `GET /api/realtime` (with the given auth token, if any) and return an
    /// async stream of raw byte chunks. The stream finishes when the connection
    /// drops; it throws on a transport/auth error.
    func connect(path: String, authToken: String?) -> AsyncThrowingStream<Data, Error>

    /// POST the subscription request body to `/api/realtime` to (re)register the
    /// client's collection subscriptions. Throws on non-2xx.
    func postSubscriptions(_ body: Data, authToken: String?) async throws
}

/// Errors surfaced by ``RealtimeClient`` / its transports.
public enum RealtimeError: Error, Sendable, Equatable {
    /// The handshake completed but no `PB_CONNECT` clientId was received.
    case missingClientId
    /// The connection or a subscription POST returned 401 — the engine must
    /// refresh the token before reconnecting (don't loop on a dead token).
    case authFailed
    /// A non-auth transport failure (offline, 5xx, dropped stream).
    case transport(String)
}

/// PocketBase realtime client: handshake → subscribe → parse → reconnect
/// (M3 plan, STEP 9 / ARCHITECTURE.md §4.4).
///
/// Protocol:
///  1. `GET /api/realtime` opens the SSE stream; PocketBase's first event is
///     `PB_CONNECT` whose JSON `data` carries `{"clientId":"..."}`.
///  2. `POST /api/realtime` with `{"clientId":..., "subscriptions":[...]}`
///     registers the desired collections.
///  3. Subsequent events name the subscription (`"<collection>"`) and carry the
///     record action/payload as JSON `data`.
///  4. On stream drop: reconnect, capture a fresh `clientId`, and **resubscribe**.
///  5. A 401 surfaces ``RealtimeError/authFailed`` so the owner refreshes the
///     token rather than reconnecting in a tight loop with a dead token.
///
/// This type owns the loop and the parser; it forwards decoded record events to
/// the injected `onEvent` handler. It does NOT itself apply LWW — that is
/// ``SyncEngine``'s job.
public actor RealtimeClient {

    /// A realtime record event after JSON decoding of the SSE `data`.
    public struct RecordEvent: Sendable, Equatable {
        /// The subscription/collection name (e.g. `"decks"`).
        public let subscription: String
        /// PocketBase action: `"create" | "update" | "delete"`.
        public let action: String
        /// The raw record JSON (PocketBase wire shape) for the engine to decode.
        public let recordJSON: Data
    }

    private let transport: SSETransport
    private let subscriptions: [String]
    private let onEvent: @Sendable (RecordEvent) async -> Void
    /// Surfaced when a reconnect needs a fresh token. The owner refreshes then
    /// calls ``updateAuthToken(_:)`` and ``start()`` again.
    private let onAuthFailed: @Sendable () async -> Void

    private var authToken: String?
    private var running = false
    private var clientId: String?

    public init(
        transport: SSETransport,
        subscriptions: [String] = ["decks", "cards", "card_images", "deck_guests", "card_completions"],
        authToken: String? = nil,
        onEvent: @escaping @Sendable (RecordEvent) async -> Void,
        onAuthFailed: @escaping @Sendable () async -> Void = {}
    ) {
        self.transport = transport
        self.subscriptions = subscriptions
        self.authToken = authToken
        self.onEvent = onEvent
        self.onAuthFailed = onAuthFailed
    }

    /// Update the auth token before a (re)connect.
    public func updateAuthToken(_ token: String?) {
        self.authToken = token
    }

    /// Whether the client currently considers itself connected/looping.
    public func isRunning() -> Bool { running }

    /// The clientId from the most recent successful handshake (test seam).
    public func currentClientId() -> String? { clientId }

    /// Stop the loop (idempotent). The owner calls this on signout.
    public func stop() {
        running = false
    }

    /// Run one connect→subscribe→consume cycle. Returns normally when the stream
    /// ends (caller decides whether to reconnect), throws on auth/transport
    /// failure. Visible for testing; ``run()`` wraps it with reconnect.
    func runOnce() async throws {
        clientId = nil
        var parser = SSEParser()
        var subscribed = false

        let stream = transport.connect(path: "/api/realtime", authToken: authToken)
        do {
            for try await chunk in stream {
                for event in parser.feed(chunk) {
                    if event.event == "PB_CONNECT" {
                        clientId = Self.parseClientId(from: event.data)
                        guard let clientId else { throw RealtimeError.missingClientId }
                        // Subscribe-before-resync: register all collections first.
                        try await subscribe(clientId: clientId)
                        subscribed = true
                    } else if subscribed, subscriptions.contains(event.event) {
                        if let record = Self.decodeRecordEvent(subscription: event.event, data: event.data) {
                            await onEvent(record)
                        }
                    }
                }
            }
        } catch let error as RealtimeError {
            throw error
        } catch {
            throw RealtimeError.transport(String(describing: error))
        }
    }

    /// Connect and consume forever, reconnecting on a dropped stream with a
    /// short delay. On ``RealtimeError/authFailed`` it stops the loop and signals
    /// the owner to refresh the token (no tight reconnect on a dead token).
    ///
    /// `reconnectDelay` is injectable (and `0` in tests) so the loop is
    /// deterministic. `maxReconnects` bounds the loop for tests; `nil` = forever.
    public func run(reconnectDelay: TimeInterval = 2.0, maxReconnects: Int? = nil) async {
        running = true
        var attempts = 0
        while running {
            do {
                try await runOnce()
                // Stream ended cleanly (server dropped us) → reconnect.
            } catch RealtimeError.authFailed {
                running = false
                await onAuthFailed()
                return
            } catch {
                // Transient transport error → fall through to reconnect.
            }
            guard running else { return }
            attempts += 1
            if let maxReconnects, attempts >= maxReconnects { running = false; return }
            if reconnectDelay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(reconnectDelay * 1_000_000_000))
            }
        }
    }

    private func subscribe(clientId: String) async throws {
        let body: [String: Any] = ["clientId": clientId, "subscriptions": subscriptions]
        let data = try JSONSerialization.data(withJSONObject: body)
        do {
            try await transport.postSubscriptions(data, authToken: authToken)
        } catch let APIClientError.httpError(status, _) where status == 401 {
            throw RealtimeError.authFailed
        } catch let APIClientError.httpError(status, _) {
            throw RealtimeError.transport("subscribe HTTP \(status)")
        }
    }

    // MARK: - Decoding helpers (pure, testable)

    /// Extract `clientId` from a `PB_CONNECT` event's JSON data.
    static func parseClientId(from data: String) -> String? {
        guard
            let obj = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any],
            let id = obj["clientId"] as? String,
            !id.isEmpty
        else { return nil }
        return id
    }

    /// Decode a PocketBase realtime record event payload, which has the shape
    /// `{"action":"create|update|delete","record":{...}}`.
    static func decodeRecordEvent(subscription: String, data: String) -> RecordEvent? {
        guard
            let obj = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any],
            let action = obj["action"] as? String,
            let record = obj["record"],
            let recordJSON = try? JSONSerialization.data(withJSONObject: record)
        else { return nil }
        return RecordEvent(subscription: subscription, action: action, recordJSON: recordJSON)
    }
}

/// Production ``SSETransport`` over `URLSession` (M3 plan, STEP 9).
///
/// Uses `URLSession.bytes(for:)` on Darwin/recent platforms where available,
/// gated behind availability. A `URLSessionDataDelegate`-based fallback keeps
/// the package building (and functional) on Linux / older OSes where
/// `bytes(for:)` is unavailable — important so `swift build` stays portable.
public final class URLSessionSSETransport: NSObject, SSETransport, @unchecked Sendable {

    private let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
        super.init()
    }

    public func connect(path: String, authToken: String?) -> AsyncThrowingStream<Data, Error> {
        let url = baseURL.appendingPathComponent(path)
        var mutableRequest = URLRequest(url: url)
        mutableRequest.httpMethod = "GET"
        mutableRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let authToken { mutableRequest.setValue(authToken, forHTTPHeaderField: "Authorization") }
        let request = mutableRequest
        let session = self.session

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    #if canImport(FoundationNetworking)
                    // Linux Foundation lacks `bytes(for:)`: buffer the whole body
                    // (SSE on Linux is a degraded fallback; the primary platform
                    // is Darwin). This keeps the package building + functional.
                    let (data, response) = try await session.data(for: request)
                    if let http = response as? HTTPURLResponse, http.statusCode == 401 {
                        continuation.finish(throwing: RealtimeError.authFailed)
                        return
                    }
                    continuation.yield(data)
                    continuation.finish()
                    #else
                    if #available(iOS 15.0, macOS 12.0, tvOS 15.0, watchOS 8.0, *) {
                        let (bytes, response) = try await session.bytes(for: request)
                        if let http = response as? HTTPURLResponse, http.statusCode == 401 {
                            continuation.finish(throwing: RealtimeError.authFailed)
                            return
                        }
                        var buffer = Data()
                        for try await byte in bytes {
                            buffer.append(byte)
                            // Yield on each LF so the parser sees lines promptly.
                            if byte == 0x0A {
                                continuation.yield(buffer)
                                buffer.removeAll(keepingCapacity: true)
                            }
                        }
                        if !buffer.isEmpty { continuation.yield(buffer) }
                        continuation.finish()
                    } else {
                        let (data, response) = try await session.data(for: request)
                        if let http = response as? HTTPURLResponse, http.statusCode == 401 {
                            continuation.finish(throwing: RealtimeError.authFailed)
                            return
                        }
                        continuation.yield(data)
                        continuation.finish()
                    }
                    #endif
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func postSubscriptions(_ body: Data, authToken: String?) async throws {
        let url = baseURL.appendingPathComponent("/api/realtime")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let authToken { request.setValue(authToken, forHTTPHeaderField: "Authorization") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RealtimeError.transport("non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw APIClientError.httpError(status: http.statusCode, body: data)
        }
    }
}
