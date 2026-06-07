import XCTest
@testable import PoseDeckCore

/// Positive-path coverage for the M3 realtime layer (replaces the old
/// `.notImplemented` stub assertion). The realtime handshake/parse logic is
/// owned by ``RealtimeClient``; exercised here via a stubbed ``SSETransport`` so
/// no live server is needed.
final class APIClientSubscribeTests: XCTestCase {

    func testRealtimeClientHandshakeSubscribesThenDeliversEvents() async throws {
        let transport = StubSSETransport()
        // PB_CONNECT (clientId) then one decks record event, then the stream drops.
        transport.state.enqueueConnect(chunks: [
            sseConnectFrame(clientId: "abc123"),
            sseRecordFrame(
                subscription: "decks",
                action: "update",
                recordJSON: #"{"id":"d1","owner":"u","name":"Hello","deleted_at":""}"#
            ),
        ])

        let received = EventBox()
        let client = RealtimeClient(
            transport: transport,
            subscriptions: ["decks"],
            authToken: "tok",
            onEvent: { event in await received.append(event) }
        )

        try await client.runOnce()

        // Subscribed exactly once, with the clientId from PB_CONNECT.
        XCTAssertEqual(transport.state.subscribeBodies.count, 1)
        let body = try JSONSerialization.jsonObject(with: transport.state.subscribeBodies[0]) as? [String: Any]
        XCTAssertEqual(body?["clientId"] as? String, "abc123")
        XCTAssertEqual(body?["subscriptions"] as? [String], ["decks"])

        let events = await received.events
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.subscription, "decks")
        XCTAssertEqual(events.first?.action, "update")
    }

    func testSubscribeHelperReturnsRunningClient() async throws {
        // The thin APIClient.subscribe(collection:onEvent:) helper builds a
        // RealtimeClient over a real URLSessionSSETransport. We only assert it
        // returns a handle we can stop (no live server is contacted in CI since
        // the connect Task is cancelled by stop()).
        let api = APIClient(baseURL: URL(string: "http://localhost:8090")!)
        let client = await api.subscribe(collection: "decks", onEvent: { _ in })
        await client.stop()
        let running = await client.isRunning()
        XCTAssertFalse(running)
    }
}

/// Async-safe collector for realtime events.
actor EventBox {
    private(set) var events: [RealtimeClient.RecordEvent] = []
    func append(_ event: RealtimeClient.RecordEvent) { events.append(event) }
}
