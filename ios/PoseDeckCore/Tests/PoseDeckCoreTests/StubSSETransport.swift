import Foundation
@testable import PoseDeckCore

/// A scripted ``SSETransport`` for offline realtime tests.
///
/// `connect` yields a queue of byte chunks (then finishes the stream, simulating
/// a server drop), or throws a scripted error. `postSubscriptions` records each
/// subscribe body and can be told to fail (e.g. to simulate a 401).
final class StubSSETransport: SSETransport, @unchecked Sendable {

    final class State: @unchecked Sendable {
        private let lock = NSLock()
        /// Per-connect scripts: each connect pops the next chunk script.
        private var _connectScripts: [[Data]] = []
        private var _connectErrors: [Error?] = []
        private var _subscribeError: Error?
        private var _subscribeBodies: [Data] = []
        private var _connectCount = 0

        func enqueueConnect(chunks: [Data], thenError: Error? = nil) {
            lock.lock(); defer { lock.unlock() }
            _connectScripts.append(chunks)
            _connectErrors.append(thenError)
        }

        func setSubscribeError(_ error: Error?) {
            lock.lock(); defer { lock.unlock() }
            _subscribeError = error
        }

        func nextConnectScript() -> ([Data], Error?) {
            lock.lock(); defer { lock.unlock() }
            _connectCount += 1
            let chunks = _connectScripts.isEmpty ? [] : _connectScripts.removeFirst()
            let err = _connectErrors.isEmpty ? nil : _connectErrors.removeFirst()
            return (chunks, err)
        }

        func recordSubscribe(_ body: Data) throws {
            lock.lock(); defer { lock.unlock() }
            _subscribeBodies.append(body)
            if let e = _subscribeError { throw e }
        }

        var subscribeBodies: [Data] { lock.lock(); defer { lock.unlock() }; return _subscribeBodies }
        var connectCount: Int { lock.lock(); defer { lock.unlock() }; return _connectCount }
    }

    let state = State()

    func connect(path: String, authToken: String?) -> AsyncThrowingStream<Data, Error> {
        let (chunks, error) = state.nextConnectScript()
        return AsyncThrowingStream { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            if let error { continuation.finish(throwing: error) } else { continuation.finish() }
        }
    }

    func postSubscriptions(_ body: Data, authToken: String?) async throws {
        try state.recordSubscribe(body)
    }
}

/// Build a `PB_CONNECT` SSE frame carrying a clientId.
func sseConnectFrame(clientId: String) -> Data {
    Data("event:PB_CONNECT\ndata:{\"clientId\":\"\(clientId)\"}\n\n".utf8)
}

/// Build a record SSE frame for a subscription/action/record-json.
func sseRecordFrame(subscription: String, action: String, recordJSON: String) -> Data {
    let payload = "{\"action\":\"\(action)\",\"record\":\(recordJSON)}"
    return Data("event:\(subscription)\ndata:\(payload)\n\n".utf8)
}
