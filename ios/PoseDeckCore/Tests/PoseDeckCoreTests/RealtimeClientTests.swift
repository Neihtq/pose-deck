import XCTest
@testable import PoseDeckCore

/// Handshake / reconnect / auth-failure coverage for ``RealtimeClient`` (M3
/// plan, STEP 9) via the stub ``SSETransport``.
final class RealtimeClientTests: XCTestCase {

    func testHandshakeCapturesClientIdAndSubscribes() async throws {
        let transport = StubSSETransport()
        transport.state.enqueueConnect(chunks: [sseConnectFrame(clientId: "cid-1")])
        let client = RealtimeClient(transport: transport, subscriptions: ["decks", "cards"], authToken: "t", onEvent: { _ in })
        try await client.runOnce()
        let cid = await client.currentClientId()
        XCTAssertEqual(cid, "cid-1")
        XCTAssertEqual(transport.state.subscribeBodies.count, 1)
        let body = try JSONSerialization.jsonObject(with: transport.state.subscribeBodies[0]) as? [String: Any]
        XCTAssertEqual(body?["subscriptions"] as? [String], ["decks", "cards"])
    }

    func testEventsBeforeSubscribeAreIgnored() async throws {
        let transport = StubSSETransport()
        // A stray record event arriving before PB_CONNECT is dropped.
        transport.state.enqueueConnect(chunks: [
            sseRecordFrame(subscription: "decks", action: "update", recordJSON: #"{"id":"d1"}"#),
            sseConnectFrame(clientId: "cid"),
        ])
        let box = EventBox()
        let client = RealtimeClient(transport: transport, subscriptions: ["decks"], authToken: nil, onEvent: { e in await box.append(e) })
        try await client.runOnce()
        let events = await box.events
        XCTAssertTrue(events.isEmpty, "events before the handshake completes are ignored")
    }

    func testReconnectResubscribesAfterDrop() async throws {
        let transport = StubSSETransport()
        // First connection: handshake then drop. Second: handshake again.
        transport.state.enqueueConnect(chunks: [sseConnectFrame(clientId: "cid-A")])
        transport.state.enqueueConnect(chunks: [sseConnectFrame(clientId: "cid-B")])
        let client = RealtimeClient(transport: transport, subscriptions: ["decks"], authToken: nil, onEvent: { _ in })
        // run() loops; bound to 2 reconnects so the test terminates.
        await client.run(reconnectDelay: 0, maxReconnects: 2)
        XCTAssertGreaterThanOrEqual(transport.state.connectCount, 2, "reconnected after drop")
        XCTAssertGreaterThanOrEqual(transport.state.subscribeBodies.count, 2, "resubscribed on reconnect")
    }

    func testAuthFailureOnSubscribeStopsAndSignals() async throws {
        let transport = StubSSETransport()
        transport.state.enqueueConnect(chunks: [sseConnectFrame(clientId: "cid")])
        transport.state.setSubscribeError(APIClientError.httpError(status: 401, body: Data()))
        let signalled = CountBox()
        let client = RealtimeClient(
            transport: transport,
            subscriptions: ["decks"],
            authToken: "dead-token",
            onEvent: { _ in },
            onAuthFailed: { signalled.increment() }
        )
        // run() should stop (not loop) on authFailed.
        await client.run(reconnectDelay: 0, maxReconnects: 5)
        XCTAssertEqual(signalled.value, 1, "auth failure signals the owner to refresh the token")
        let running = await client.isRunning()
        XCTAssertFalse(running, "does not loop on a dead token")
    }

    func testStopHaltsTheLoop() async {
        let transport = StubSSETransport()
        let client = RealtimeClient(transport: transport, subscriptions: ["decks"], onEvent: { _ in })
        await client.stop()
        let running = await client.isRunning()
        XCTAssertFalse(running)
    }

    func testParseClientIdHelper() {
        XCTAssertEqual(RealtimeClient.parseClientId(from: #"{"clientId":"abc"}"#), "abc")
        XCTAssertNil(RealtimeClient.parseClientId(from: #"{"other":"x"}"#))
        XCTAssertNil(RealtimeClient.parseClientId(from: "not-json"))
    }

    func testDecodeRecordEventHelper() throws {
        let event = RealtimeClient.decodeRecordEvent(
            subscription: "cards",
            data: #"{"action":"create","record":{"id":"c1","title":"x"}}"#
        )
        XCTAssertEqual(event?.subscription, "cards")
        XCTAssertEqual(event?.action, "create")
        let obj = try JSONSerialization.jsonObject(with: event!.recordJSON) as? [String: Any]
        XCTAssertEqual(obj?["id"] as? String, "c1")
    }
}
