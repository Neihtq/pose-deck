import XCTest
@testable import PoseDeckCore

/// Coverage for the offline-first write path (M3 plan, STEP 8): each mutation
/// mints a client id (creates), writes the LocalStore optimistically, and
/// enqueues exactly one outbox entry carrying the PocketBase wire body. No
/// network call happens on the calling path.
final class OfflineWritePathTests: XCTestCase {

    private let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

    private func makePath(store: InMemoryLocalStore, outbox: InMemoryOutbox, ids: [String] = ["id000000000000a"]) -> OfflineWritePath {
        let box = IdSeq(ids)
        let now = fixedNow
        return OfflineWritePath(
            store: store,
            outbox: outbox,
            now: { now },
            newId: { box.next() }
        )
    }

    func testCreateDeckWritesStoreAndEnqueuesOneEntry() async throws {
        let store = InMemoryLocalStore()
        let outbox = InMemoryOutbox()
        let path = makePath(store: store, outbox: outbox, ids: ["deck00000000001"])

        let deck = try await path.createDeck(name: "Shoot", ownerId: "u1")
        XCTAssertEqual(deck.id, "deck00000000001", "client-minted id used")

        // Local store has the optimistic row immediately.
        let stored = await store.deck(id: "deck00000000001")
        XCTAssertEqual(stored?.name, "Shoot")
        XCTAssertNotNil(stored?.clientUpdatedAt)

        // Exactly one create entry queued, carrying the client id in the body.
        let pending = await outbox.pending()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.type, .create)
        XCTAssertEqual(pending.first?.entity, "decks")
        let body = try JSONSerialization.jsonObject(with: pending[0].payload) as? [String: Any]
        XCTAssertEqual(body?["id"] as? String, "deck00000000001")
        XCTAssertEqual(body?["owner"] as? String, "u1")
        XCTAssertEqual(body?["name"] as? String, "Shoot")
    }

    func testCreateCardComputesPositionFromLocalStore() async throws {
        let store = InMemoryLocalStore()
        await store.upsertCard(Card(id: "c1", deck: "d1", position: 1000, title: "a", clientUpdatedAt: fixedNow))
        let outbox = InMemoryOutbox()
        let path = makePath(store: store, outbox: outbox, ids: ["card00000000001"])

        let card = try await path.createCard(deckId: "d1", fields: .init(title: "New"))
        XCTAssertEqual(card.position, 2000, "appended after the existing card via local store")

        let pending = await outbox.pending()
        XCTAssertEqual(pending.count, 1)
        let body = try JSONSerialization.jsonObject(with: pending[0].payload) as? [String: Any]
        XCTAssertEqual(body?["position"] as? Int, 2000)
        XCTAssertEqual(body?["id"] as? String, "card00000000001")
    }

    func testSoftDeleteDeckStampsDeletedAtLocallyAndEnqueuesUpdate() async throws {
        let store = InMemoryLocalStore()
        let deck = Deck(id: "d1", owner: "u", name: "x", clientUpdatedAt: Date(timeIntervalSince1970: 1))
        await store.upsertDeck(deck)
        let outbox = InMemoryOutbox()
        let path = makePath(store: store, outbox: outbox)

        try await path.softDeleteDeck(deck)
        let stored = await store.deck(id: "d1")
        XCTAssertNotNil(stored?.deletedAt, "soft-deleted locally")

        let pending = await outbox.pending()
        XCTAssertEqual(pending.first?.type, .update)
        let body = try JSONSerialization.jsonObject(with: pending[0].payload) as? [String: Any]
        XCTAssertNotEqual(body?["deleted_at"] as? String, "", "deleted_at set to a stamp")
    }

    func testReorderEnqueuesOnlyMovedCardsAsOneUnit() async throws {
        let store = InMemoryLocalStore()
        // a@1000, b@2000, c@3000
        await store.upsertCard(Card(id: "a", deck: "d", position: 1000, title: "a", clientUpdatedAt: fixedNow))
        await store.upsertCard(Card(id: "b", deck: "d", position: 2000, title: "b", clientUpdatedAt: fixedNow))
        await store.upsertCard(Card(id: "c", deck: "d", position: 3000, title: "c", clientUpdatedAt: fixedNow))
        let outbox = InMemoryOutbox()
        let path = makePath(store: store, outbox: outbox)

        // New order c,a,b → a:1000->2000, b:2000->3000, c:3000->1000 — all move.
        let moved = try await path.reorderCards(deckId: "d", orderedIds: ["c", "a", "b"])
        XCTAssertEqual(Set(moved), Set(["a", "b", "c"]))
        let pending = await outbox.pending()
        XCTAssertEqual(pending.count, 3, "one entry per moved card, single logical unit")
        // All share the same client_updated_at stamp.
        let stamps = try pending.map { entry -> String in
            let obj = try JSONSerialization.jsonObject(with: entry.payload) as? [String: Any]
            return obj?["client_updated_at"] as? String ?? ""
        }
        XCTAssertEqual(Set(stamps).count, 1, "reorder shares one stamp across the unit")
    }

    func testReorderSkipsUnmovedCards() async throws {
        let store = InMemoryLocalStore()
        await store.upsertCard(Card(id: "a", deck: "d", position: 1000, title: "a", clientUpdatedAt: fixedNow))
        await store.upsertCard(Card(id: "b", deck: "d", position: 2000, title: "b", clientUpdatedAt: fixedNow))
        let outbox = InMemoryOutbox()
        let path = makePath(store: store, outbox: outbox)

        // Same order → no card moves.
        let moved = try await path.reorderCards(deckId: "d", orderedIds: ["a", "b"])
        XCTAssertTrue(moved.isEmpty, "no entries enqueued when nothing moved")
        let pending = await outbox.pending()
        XCTAssertTrue(pending.isEmpty)
    }

    func testDeleteCardImageHardRemovesAndEnqueuesDelete() async throws {
        let store = InMemoryLocalStore()
        let img = CardImage(id: "i1", card: "c", position: 1, file: "x.jpg")
        await store.upsertCardImage(img)
        let outbox = InMemoryOutbox()
        let path = makePath(store: store, outbox: outbox)

        try await path.deleteCardImage(img)
        let gone = await store.cardImage(id: "i1")
        XCTAssertNil(gone, "image hard-removed from mirror")
        let pending = await outbox.pending()
        XCTAssertEqual(pending.first?.type, .delete)
        XCTAssertEqual(pending.first?.entity, "card_images")
    }

    func testRevokeGuestHardRemovesAndEnqueuesDelete() async throws {
        let store = InMemoryLocalStore()
        let guest = DeckGuest(id: "g1", deck: "d", user: "u", grantedAt: Date())
        await store.upsertDeckGuest(guest)
        let outbox = InMemoryOutbox()
        let path = makePath(store: store, outbox: outbox)

        try await path.revokeGuest(guest)
        let gone = await store.deckGuest(id: "g1")
        XCTAssertNil(gone)
        let pending = await outbox.pending()
        XCTAssertEqual(pending.first?.type, .delete)
        XCTAssertEqual(pending.first?.entity, "deck_guests")
    }
}

/// Deterministic id source for write-path tests.
final class IdSeq: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [String]
    private var fallback = 0
    init(_ ids: [String]) { self.ids = ids }
    func next() -> String {
        lock.lock(); defer { lock.unlock() }
        if !ids.isEmpty { return ids.removeFirst() }
        fallback += 1
        return "gen\(String(format: "%012d", fallback))"
    }
}
