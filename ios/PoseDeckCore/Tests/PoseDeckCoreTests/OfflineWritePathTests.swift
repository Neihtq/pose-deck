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

    /// Regression (CORR-IOS-DUP-NAME-CLAMP): the production offline-first
    /// `duplicateDeck` (MirrorDeckRepository) routes its " (copy)" name through
    /// `OfflineWritePath.createDeck`, which previously did NOT clamp `name` to the
    /// 200-char DB ceiling. A source name within 7 chars of 200 overflowed once
    /// " (copy)" was appended, producing an optimistic local deck plus an outbox
    /// create the server 4xxes and drops — a silent ghost duplicate. The clamp in
    /// `createDeck` is the chokepoint that protects EVERY offline create; this
    /// asserts both the optimistic local row and the enqueued wire body land at or
    /// under the ceiling. Mirrors DeckRepositoryTests.testDuplicateDeckClampsCopyNameToDbCeiling.
    func testCreateDeckClampsOverlongNameToDbCeiling() async throws {
        let store = InMemoryLocalStore()
        let outbox = InMemoryOutbox()
        let path = makePath(store: store, outbox: outbox, ids: ["deck00000000001"])

        // Simulate the duplicate path's worst case: a 200-char source name plus
        // the " (copy)" suffix = 207 chars handed to createDeck.
        let overlong = String(repeating: "A", count: DeckRepository.nameMaxLength) + " (copy)"
        XCTAssertGreaterThan(overlong.count, DeckRepository.nameMaxLength)

        let deck = try await path.createDeck(name: overlong, ownerId: "u1")

        // Optimistic local row is clamped.
        XCTAssertEqual(deck.name.count, DeckRepository.nameMaxLength, "returned deck name clamped")
        let stored = await store.deck(id: "deck00000000001")
        XCTAssertEqual(stored?.name.count, DeckRepository.nameMaxLength, "mirror row name clamped")

        // The enqueued wire body the server will receive is at/under the ceiling,
        // so the create is no longer rejected and dropped.
        let pending = await outbox.pending()
        XCTAssertEqual(pending.count, 1)
        let body = try JSONSerialization.jsonObject(with: pending[0].payload) as? [String: Any]
        let wireName = try XCTUnwrap(body?["name"] as? String)
        XCTAssertLessThanOrEqual(wireName.count, DeckRepository.nameMaxLength, "wire name clamped to DB ceiling")
        XCTAssertEqual(wireName, deck.name, "mirror and wire names agree")
    }

    /// Regression (SPEC-IOS-1): the offline `renameDeck` previously forwarded the
    /// raw `name` into both the optimistic local row and the outbox update body. A
    /// rename >200 chars wrote an optimistic local row but produced an outbox
    /// update the server 4xxes and drops — leaving the mirror permanently out of
    /// sync with the server. The clamp mirrors `createDeck`'s chokepoint and the
    /// web `deckApi.ts` `maxLength={200}` input cap.
    func testRenameDeckClampsOverlongNameToDbCeiling() async throws {
        let store = InMemoryLocalStore()
        let outbox = InMemoryOutbox()
        let path = makePath(store: store, outbox: outbox)

        // Seed with an older clock so the rename (stamped at fixedNow) wins LWW.
        let deck = Deck(id: "deck00000000001", owner: "u1", name: "Old",
                        clientUpdatedAt: fixedNow.addingTimeInterval(-60))
        await store.upsertDeck(deck)

        let overlong = String(repeating: "B", count: DeckRepository.nameMaxLength + 50)
        try await path.renameDeck(deck, name: overlong)

        // Optimistic local row is clamped.
        let stored = await store.deck(id: "deck00000000001")
        XCTAssertEqual(stored?.name.count, DeckRepository.nameMaxLength, "mirror row name clamped")

        // The enqueued update body is at/under the ceiling so the PATCH is accepted.
        let pending = await outbox.pending()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.type, .update)
        let body = try JSONSerialization.jsonObject(with: pending[0].payload) as? [String: Any]
        let wireName = try XCTUnwrap(body?["name"] as? String)
        XCTAssertEqual(wireName.count, DeckRepository.nameMaxLength, "wire name clamped to DB ceiling")
        XCTAssertEqual(wireName, stored?.name, "mirror and wire names agree")
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

    func testSoftDeleteDeckCascadesHideToChildrenLocally() async throws {
        let store = InMemoryLocalStore()
        let deckStamp = Date(timeIntervalSince1970: 1)
        let deck = Deck(id: "d1", owner: "u", name: "x", clientUpdatedAt: deckStamp)
        await store.upsertDeck(deck)

        // Two live children, one with an image; plus a card in another deck that
        // must be untouched, and an already-trashed child whose own deletedAt
        // (not the deck stamp) must be preserved.
        let childStamp = Date(timeIntervalSince1970: 500)
        await store.upsertCard(Card(id: "c1", deck: "d1", position: 1000, title: "a", clientUpdatedAt: childStamp))
        await store.upsertCard(Card(id: "c2", deck: "d1", position: 2000, title: "b", clientUpdatedAt: childStamp))
        let preTrashStamp = Date(timeIntervalSince1970: 600)
        await store.upsertCard(Card(id: "c3", deck: "d1", position: 3000, title: "c", clientUpdatedAt: childStamp, deletedAt: preTrashStamp))
        await store.upsertCard(Card(id: "other", deck: "d2", position: 1000, title: "z", clientUpdatedAt: childStamp))
        await store.upsertCardImage(CardImage(id: "img1", card: "c1", position: 1, file: "x.jpg"))

        let outbox = InMemoryOutbox()
        let path = makePath(store: store, outbox: outbox)

        try await path.softDeleteDeck(deck)

        // Live children are hidden, stamped with the deck's soft-delete stamp,
        // while their real LWW clock (client_updated_at) is preserved.
        for id in ["c1", "c2"] {
            let card = await store.card(id: id)
            XCTAssertEqual(card?.deletedAt, fixedNow, "\(id) hidden at the deck stamp")
            XCTAssertEqual(card?.clientUpdatedAt, childStamp, "\(id) LWW clock untouched")
        }
        // The child's image is evicted from the mirror.
        let img = await store.cardImage(id: "img1")
        XCTAssertNil(img, "child card image evicted on deck soft-delete")

        // listCards (cards(deckId:)) still returns the rows, but all carry a
        // deletedAt so the deck's card list filters them out as hidden.
        let children = await store.cards(deckId: "d1")
        XCTAssertTrue(children.allSatisfy { $0.deletedAt != nil }, "no live child survives the deck soft-delete")

        // An already-trashed child keeps its own deletedAt (not re-stamped).
        let preTrashed = await store.card(id: "c3")
        XCTAssertEqual(preTrashed?.deletedAt, preTrashStamp, "individually-trashed child keeps its own stamp")

        // A card in a different deck is left alone.
        let other = await store.card(id: "other")
        XCTAssertNil(other?.deletedAt, "unrelated deck's card untouched")

        // Only the deck row is enqueued (server cascade carries the children).
        let pending = await outbox.pending()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.entity, "decks")
        XCTAssertEqual(pending.first?.type, .update)
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

    /// Regression (CORR-2): a mid-loop enqueue failure must leave the local
    /// mirror in the EXACT pre-reorder order, not a neither-old-nor-new partial
    /// restripe. `OfflineWritePath.reorderCards` upserts each moved card's new
    /// position into the store *before* its outbox enqueue; the view-model's
    /// catch path only reverts the in-memory `cards` array
    /// (`CardRepository.restoredOrder`) and never touches the store, so without
    /// an atomic rollback here a partial store write survives and a later
    /// `load()`/`refresh()` (which reads the store sorted by position)
    /// re-surfaces the corrupted order. This drives a failure on the 2nd moved
    /// card and asserts (a) the call rethrows, (b) every card's stored position
    /// AND `clientUpdatedAt` are back to their pre-drag values, and (c) the
    /// store sorted by position yields the original ordering.
    func testReorderRollsBackMirrorOnMidLoopEnqueueFailure() async throws {
        let store = InMemoryLocalStore()
        let originalStamp = fixedNow.addingTimeInterval(-3600)
        // a@1000, b@2000, c@3000
        await store.upsertCard(Card(id: "a", deck: "d", position: 1000, title: "a", clientUpdatedAt: originalStamp))
        await store.upsertCard(Card(id: "b", deck: "d", position: 2000, title: "b", clientUpdatedAt: originalStamp))
        await store.upsertCard(Card(id: "c", deck: "d", position: 3000, title: "c", clientUpdatedAt: originalStamp))
        let outbox = InMemoryOutbox()

        // Fail on the SECOND card the loop tries to enqueue, so at least one card
        // (the first) has already had its new position written to the store —
        // exactly the partial-restripe window CORR-2 describes.
        let failCounter = Counter()
        struct InjectedEnqueueError: Error {}
        let now = fixedNow
        let path = OfflineWritePath(
            store: store,
            outbox: outbox,
            now: { now },
            newId: { "unused" },
            enqueueFault: { _ in
                if failCounter.bump() == 2 { throw InjectedEnqueueError() }
            }
        )

        // New order c,a,b → all three cards move, so the loop reaches a 2nd card.
        do {
            _ = try await path.reorderCards(deckId: "d", orderedIds: ["c", "a", "b"])
            XCTFail("reorderCards should rethrow the injected enqueue failure")
        } catch is InjectedEnqueueError {
            // expected
        }

        // The mirror is back in the exact pre-reorder state: positions AND the
        // LWW clock are untouched for every card (no half-applied restripe, no
        // bumped client_updated_at on the one card that was optimistically moved).
        for (id, pos) in [("a", 1000), ("b", 2000), ("c", 3000)] {
            let card = await store.card(id: id)
            XCTAssertEqual(card?.position, pos, "\(id) position rolled back to pre-reorder")
            XCTAssertEqual(card?.clientUpdatedAt, originalStamp, "\(id) LWW clock not bumped by the failed reorder")
        }

        // listCards (store sorted by position) yields the original order — a
        // later load()/refresh() will NOT re-surface a corrupted ordering.
        let stored = await store.cards(deckId: "d")
        XCTAssertEqual(stored.map(\.id), ["a", "b", "c"], "mirror order is the pre-drag order")
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

/// Thread-safe monotonic counter for fault-injection tests (returns the
/// post-increment count, i.e. first call returns 1).
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func bump() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
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
