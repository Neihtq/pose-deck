import XCTest
@testable import PoseDeckCore

/// Coverage for ``SyncEngine`` (M3 plan, STEP 9): per-collection LWW, self-echo
/// suppression, image create/delete, guest revoke, and deck soft-delete cascade.
final class SyncEngineTests: XCTestCase {

    private func wireDate(_ s: TimeInterval) -> String {
        PocketBaseDate.string(from: Date(timeIntervalSince1970: s))
    }

    private func event(_ subscription: String, _ action: String, _ json: String) -> RealtimeClient.RecordEvent {
        RealtimeClient.RecordEvent(subscription: subscription, action: action, recordJSON: Data(json.utf8))
    }

    // MARK: - LWW per collection

    func testDeckUpdateAppliesWhenNewer() async {
        let store = InMemoryLocalStore()
        await store.upsertDeck(Deck(id: "d1", owner: "u", name: "old", clientUpdatedAt: Date(timeIntervalSince1970: 1)))
        let engine = SyncEngine(store: store)
        let applied = await engine.apply(event("decks", "update",
            #"{"id":"d1","owner":"u","name":"new","client_updated_at":"\#(wireDate(2))","deleted_at":""}"#))
        XCTAssertTrue(applied)
        let result = await store.deck(id: "d1")
        XCTAssertEqual(result?.name, "new")
    }

    func testDeckStaleEventLosesLWW() async {
        let store = InMemoryLocalStore()
        await store.upsertDeck(Deck(id: "d1", owner: "u", name: "current", clientUpdatedAt: Date(timeIntervalSince1970: 5)))
        let engine = SyncEngine(store: store)
        let applied = await engine.apply(event("decks", "update",
            #"{"id":"d1","owner":"u","name":"stale","client_updated_at":"\#(wireDate(2))","deleted_at":""}"#))
        XCTAssertFalse(applied, "older client_updated_at must lose")
        let result = await store.deck(id: "d1")
        XCTAssertEqual(result?.name, "current")
    }

    func testCompletionKeysOnChangedAt() async {
        let store = InMemoryLocalStore()
        await store.upsertCardCompletion(CardCompletion(id: "x", card: "c", user: "u", state: .pending, changedAt: Date(timeIntervalSince1970: 1)))
        let engine = SyncEngine(store: store)
        let applied = await engine.apply(event("card_completions", "update",
            #"{"id":"x","card":"c","user":"u","state":"done","changed_at":"\#(wireDate(2))"}"#))
        XCTAssertTrue(applied)
        let result = await store.cardCompletion(id: "x")
        XCTAssertEqual(result?.state, .done)
    }

    // MARK: - Self-echo suppression (invariant #4)

    func testSelfEchoIsSuppressed() async {
        let store = InMemoryLocalStore()
        let engine = SyncEngine(store: store)
        await engine.noteConfirmed(entity: "decks", recordId: "d1")
        // An echo for our own just-confirmed write is skipped regardless of LWW.
        let applied = await engine.apply(event("decks", "create",
            #"{"id":"d1","owner":"u","name":"echo","client_updated_at":"\#(wireDate(99))","deleted_at":""}"#))
        XCTAssertFalse(applied, "self-echo must be suppressed")
        let result = await store.deck(id: "d1")
        XCTAssertNil(result, "echo did not write the store")
    }

    func testEchoSuppressionExpiresAfterTTL() async {
        let clockBox = ClockBox(start: Date(timeIntervalSince1970: 1000))
        let store = InMemoryLocalStore()
        let engine = SyncEngine(store: store, echoTTL: 5, now: { clockBox.now })
        await engine.noteConfirmed(entity: "decks", recordId: "d1")
        let suppressedNow = await engine.isSuppressed(entity: "decks", id: "d1")
        XCTAssertTrue(suppressedNow)
        clockBox.advance(by: 10) // past TTL
        let suppressedLater = await engine.isSuppressed(entity: "decks", id: "d1")
        XCTAssertFalse(suppressedLater, "echo guard expires after TTL")
    }

    // MARK: - Images: create (insert) + delete (hard)

    func testImageCreateInserts() async {
        let store = InMemoryLocalStore()
        let engine = SyncEngine(store: store)
        let applied = await engine.apply(event("card_images", "create",
            #"{"id":"i1","card":"c1","position":1,"file":"a.jpg"}"#))
        XCTAssertTrue(applied)
        let img = await store.cardImage(id: "i1")
        XCTAssertEqual(img?.file, "a.jpg")
    }

    func testImageDeleteHardRemoves() async {
        let store = InMemoryLocalStore()
        await store.upsertCardImage(CardImage(id: "i1", card: "c1", position: 1, file: "a.jpg"))
        let engine = SyncEngine(store: store)
        let applied = await engine.apply(event("card_images", "delete", #"{"id":"i1"}"#))
        XCTAssertTrue(applied)
        let img = await store.cardImage(id: "i1")
        XCTAssertNil(img, "image hard-deleted")
    }

    // MARK: - Guests: grant (insert) + revoke (delete)

    func testGuestRevokeHardRemoves() async {
        let store = InMemoryLocalStore()
        await store.upsertDeckGuest(DeckGuest(id: "g1", deck: "d1", user: "u", grantedAt: Date()))
        let engine = SyncEngine(store: store)
        let applied = await engine.apply(event("deck_guests", "delete", #"{"id":"g1"}"#))
        XCTAssertTrue(applied)
        let g = await store.deckGuest(id: "g1")
        XCTAssertNil(g)
    }

    // MARK: - Deck soft-delete cascade

    func testDeckSoftDeleteCascadesToChildren() async {
        let store = InMemoryLocalStore()
        await store.upsertDeck(Deck(id: "d1", owner: "u", name: "x", clientUpdatedAt: Date(timeIntervalSince1970: 1)))
        await store.upsertCard(Card(id: "c1", deck: "d1", position: 1000, title: "a", clientUpdatedAt: Date(timeIntervalSince1970: 1)))
        await store.upsertCardImage(CardImage(id: "i1", card: "c1", position: 1, file: "a.jpg"))
        let engine = SyncEngine(store: store)

        // Incoming soft-delete of the deck (deleted_at set).
        let applied = await engine.apply(event("decks", "update",
            #"{"id":"d1","owner":"u","name":"x","client_updated_at":"\#(wireDate(5))","deleted_at":"\#(wireDate(5))"}"#))
        XCTAssertTrue(applied)

        let deck = await store.deck(id: "d1")
        XCTAssertNotNil(deck?.deletedAt, "deck soft-deleted")
        let card = await store.card(id: "c1")
        XCTAssertNotNil(card?.deletedAt, "child card hidden by cascade")
        let img = await store.cardImage(id: "i1")
        XCTAssertNil(img, "child image evicted by cascade")
    }

    func testDeckHardDeleteEventCascades() async {
        let store = InMemoryLocalStore()
        await store.upsertDeck(Deck(id: "d1", owner: "u", name: "x", clientUpdatedAt: Date(timeIntervalSince1970: 1)))
        await store.upsertCardImage(CardImage(id: "i1", card: "c1", position: 1, file: "a.jpg"))
        await store.upsertCard(Card(id: "c1", deck: "d1", position: 1000, title: "a", clientUpdatedAt: Date(timeIntervalSince1970: 1)))
        let engine = SyncEngine(store: store)
        let applied = await engine.apply(event("decks", "delete", #"{"id":"d1"}"#))
        XCTAssertTrue(applied)
        let img = await store.cardImage(id: "i1")
        XCTAssertNil(img, "hard delete event cascades to evict child images")
    }
}

/// Thread-safe mutable clock for engine TTL tests.
final class ClockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date
    init(start: Date) { _now = start }
    var now: Date { lock.lock(); defer { lock.unlock() }; return _now }
    func advance(by t: TimeInterval) { lock.lock(); defer { lock.unlock() }; _now = _now.addingTimeInterval(t) }
}
