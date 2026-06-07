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
        // The cascade hide must NOT poison the LWW clock: client_updated_at stays
        // the card's real value so a later server re-apply can win (regression: C1).
        XCTAssertEqual(card?.clientUpdatedAt, Date(timeIntervalSince1970: 1),
                       "cascade must preserve the child's client_updated_at, not fabricate now()")
        let img = await store.cardImage(id: "i1")
        XCTAssertNil(img, "child image evicted by cascade")
    }

    /// Regression for C1: a realtime deck-delete cascade hid child cards by
    /// stamping a fabricated `now()` into BOTH `deleted_at` AND
    /// `client_updated_at`. Because the local store and resync backfill both apply
    /// LWW on `client_updated_at`, that future clock permanently beat the genuine
    /// (older) server card, so the card stayed hidden forever — even after the
    /// deck was restored. The fix (a) preserves the child's real clock when
    /// hiding, so the cascade can never poison LWW, and (b) un-hides cascaded
    /// children on the deck-restore transition.
    func testDeckDeleteThenRestoreReLivesChildCard() async {
        let store = InMemoryLocalStore()
        // Live deck + card from another device, both with an OLD client clock.
        await store.upsertDeck(Deck(id: "d1", owner: "u", name: "x", clientUpdatedAt: Date(timeIntervalSince1970: 1)))
        await store.upsertCard(Card(id: "c1", deck: "d1", position: 1000, title: "a", clientUpdatedAt: Date(timeIntervalSince1970: 1)))
        // Engine clock is "far future" — this is exactly the now() the old cascade
        // fabricated into the card's LWW clock and that permanently shadowed it.
        let clock = ClockBox(start: Date(timeIntervalSince1970: 10_000))
        let engine = SyncEngine(store: store, now: { clock.now })

        // 1) Another device soft-deletes the deck (realtime event, not our echo).
        let deleted = await engine.apply(event("decks", "update",
            #"{"id":"d1","owner":"u","name":"x","client_updated_at":"\#(wireDate(5))","deleted_at":"\#(wireDate(5))"}"#))
        XCTAssertTrue(deleted)
        let hidden = await store.card(id: "c1")
        XCTAssertNotNil(hidden?.deletedAt, "child hidden while deck is deleted")
        // The cascade must NOT have fabricated a future client clock.
        XCTAssertEqual(hidden?.clientUpdatedAt, Date(timeIntervalSince1970: 1),
                       "cascade preserved the child's real LWW clock")

        // 2) Deck is restored (server clears deleted_at on the DECK row only).
        let restored = await engine.apply(event("decks", "update",
            #"{"id":"d1","owner":"u","name":"x","client_updated_at":"\#(wireDate(6))","deleted_at":""}"#))
        XCTAssertTrue(restored)

        let card = await store.card(id: "c1")
        XCTAssertNil(card?.deletedAt, "child card returns to LIVE after deck restore — not permanently shadowed")

        // 3) A later reconciling backfill re-delivers the genuine server card with
        //    its ORIGINAL older clock — it must NOT re-hide or churn the live card.
        await store.upsertCard(Card(id: "c1", deck: "d1", position: 1000, title: "a",
                                    clientUpdatedAt: Date(timeIntervalSince1970: 1)))
        let afterBackfill = await store.card(id: "c1")
        XCTAssertNil(afterBackfill?.deletedAt, "backfill of the live server card keeps it live")
    }

    /// A card the user individually soft-deleted must stay trashed across a deck
    /// delete→restore round trip (the restore cascade only un-hides children it
    /// hid itself, keyed on the deck's own deleted_at stamp).
    func testIndividuallyTrashedCardStaysTrashedAfterDeckRestore() async {
        let store = InMemoryLocalStore()
        await store.upsertDeck(Deck(id: "d1", owner: "u", name: "x", clientUpdatedAt: Date(timeIntervalSince1970: 1)))
        // c1 is live; c2 was individually trashed earlier with its OWN deleted_at.
        await store.upsertCard(Card(id: "c1", deck: "d1", position: 1000, title: "a", clientUpdatedAt: Date(timeIntervalSince1970: 1)))
        await store.upsertCard(Card(id: "c2", deck: "d1", position: 2000, title: "b",
                                    clientUpdatedAt: Date(timeIntervalSince1970: 2),
                                    deletedAt: Date(timeIntervalSince1970: 3)))
        let engine = SyncEngine(store: store)

        await engine.apply(event("decks", "update",
            #"{"id":"d1","owner":"u","name":"x","client_updated_at":"\#(wireDate(5))","deleted_at":"\#(wireDate(5))"}"#))
        await engine.apply(event("decks", "update",
            #"{"id":"d1","owner":"u","name":"x","client_updated_at":"\#(wireDate(6))","deleted_at":""}"#))

        let c1 = await store.card(id: "c1")
        XCTAssertNil(c1?.deletedAt, "cascade-hidden card returns to live")
        let c2 = await store.card(id: "c2")
        XCTAssertEqual(c2?.deletedAt, Date(timeIntervalSince1970: 3),
                       "individually-trashed card keeps its own deleted_at — not resurrected by deck restore")
    }

    // MARK: - Card delete event (defensive hard-delete tombstone)

    /// Regression for swift-1: a realtime `delete` action on a card used to only
    /// evict the card's images, leaving the card row LIVE (deleted_at == nil) in
    /// the mirror — so a card deleted on another client kept showing on this
    /// device until a full resync. The fix stamps a display tombstone via
    /// hideCard (deleted_at set, client_updated_at preserved) so listCards
    /// excludes it, while never poisoning the LWW clock.
    func testCardDeleteEventTombstonesCard() async {
        let store = InMemoryLocalStore()
        await store.upsertCard(Card(id: "c1", deck: "d1", position: 1000, title: "a",
                                    clientUpdatedAt: Date(timeIntervalSince1970: 1)))
        await store.upsertCardImage(CardImage(id: "i1", card: "c1", position: 1, file: "a.jpg"))
        let clock = ClockBox(start: Date(timeIntervalSince1970: 10_000))
        let engine = SyncEngine(store: store, now: { clock.now })

        let applied = await engine.apply(event("cards", "delete", #"{"id":"c1"}"#))
        XCTAssertTrue(applied, "card delete event changed the store")

        let card = await store.card(id: "c1")
        XCTAssertNotNil(card?.deletedAt, "deleted card is tombstoned (hidden), not left live")
        // listCards parity: only deleted_at == nil cards survive the read filter.
        let visible = await store.cards(deckId: "d1").filter { $0.deletedAt == nil }
        XCTAssertTrue(visible.isEmpty, "tombstoned card no longer appears in the deck listing")
        // The hide must preserve the card's real LWW clock (same contract as the
        // deck cascade), never fabricating a future now() that would shadow a
        // genuine server re-apply.
        XCTAssertEqual(card?.clientUpdatedAt, Date(timeIntervalSince1970: 1),
                       "delete tombstone preserves client_updated_at")
        let img = await store.cardImage(id: "i1")
        XCTAssertNil(img, "child image evicted by card delete")
    }

    /// A card delete event for a card not present locally reports no change.
    func testCardDeleteEventUnknownCardIsNoOp() async {
        let store = InMemoryLocalStore()
        let engine = SyncEngine(store: store)
        let applied = await engine.apply(event("cards", "delete", #"{"id":"missing"}"#))
        XCTAssertFalse(applied, "deleting an unknown card changes nothing")
    }

    /// Regression for swift-2: a realtime `delete` action on a deck used to only
    /// cascade to its children (evict images, hide cards) but never touch the deck
    /// row itself — the `keepDeckRow=false` flag was effectively dead, so a deck
    /// hard-deleted server-side stayed listed (deletedAt == nil) on this device.
    /// The fix stamps a display tombstone on the deck via hideDeck (deleted_at set,
    /// client_updated_at preserved) so listDecks excludes it, while never poisoning
    /// the LWW clock.
    func testDeckHardDeleteEventTombstonesDeckRow() async {
        let store = InMemoryLocalStore()
        await store.upsertDeck(Deck(id: "d1", owner: "u", name: "x", clientUpdatedAt: Date(timeIntervalSince1970: 1)))
        await store.upsertCardImage(CardImage(id: "i1", card: "c1", position: 1, file: "a.jpg"))
        await store.upsertCard(Card(id: "c1", deck: "d1", position: 1000, title: "a", clientUpdatedAt: Date(timeIntervalSince1970: 1)))
        let clock = ClockBox(start: Date(timeIntervalSince1970: 10_000))
        let engine = SyncEngine(store: store, now: { clock.now })

        let applied = await engine.apply(event("decks", "delete", #"{"id":"d1"}"#))
        XCTAssertTrue(applied)

        let deck = await store.deck(id: "d1")
        XCTAssertNotNil(deck?.deletedAt, "deleted deck is tombstoned (hidden), not left live")
        // listDecks parity (MirrorDeckRepository): only deleted_at == nil decks survive.
        let visible = await store.allDecks().filter { $0.deletedAt == nil }
        XCTAssertTrue(visible.isEmpty, "tombstoned deck no longer appears in the deck listing")
        // The hide must preserve the deck's real LWW clock (same contract as the
        // child cascade), never fabricating a future now() that would shadow a
        // genuine server re-apply.
        XCTAssertEqual(deck?.clientUpdatedAt, Date(timeIntervalSince1970: 1),
                       "delete tombstone preserves the deck's client_updated_at")
        // And it still cascades to children.
        let img = await store.cardImage(id: "i1")
        XCTAssertNil(img, "hard delete event cascades to evict child images")
        let card = await store.card(id: "c1")
        XCTAssertNotNil(card?.deletedAt, "hard delete event cascades to hide child cards")
    }

    /// A deck delete event for a deck not present locally reports a change (the
    /// cascade is a safe no-op) but cannot resurrect or list anything.
    func testDeckHardDeleteEventUnknownDeckListsNothing() async {
        let store = InMemoryLocalStore()
        let engine = SyncEngine(store: store)
        let applied = await engine.apply(event("decks", "delete", #"{"id":"missing"}"#))
        XCTAssertTrue(applied)
        let visible = await store.allDecks().filter { $0.deletedAt == nil }
        XCTAssertTrue(visible.isEmpty, "no deck appears for an unknown delete")
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
