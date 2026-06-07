import XCTest
@testable import PoseDeckCore

/// M5 sharing regression coverage (PHASE C): the offline grant write path, the
/// `deck_guests` duplicate-grant 400-as-success classification, the SyncEngine
/// guest CREATE/DELETE semantics (hydrate-on-self-grant, evict-on-foreign-revoke,
/// keep-own, absent-noop), and the email resolver's query shape.
final class SharingTests: XCTestCase {

    private let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

    private func makePath(store: InMemoryLocalStore, outbox: InMemoryOutbox, ids: [String]) -> OfflineWritePath {
        let box = IdSeq(ids)
        let now = fixedNow
        return OfflineWritePath(store: store, outbox: outbox, now: { now }, newId: { box.next() })
    }

    private func event(_ subscription: String, _ action: String, _ json: String) -> RealtimeClient.RecordEvent {
        RealtimeClient.RecordEvent(subscription: subscription, action: action, recordJSON: Data(json.utf8))
    }

    private func wireDate(_ s: TimeInterval) -> String {
        PocketBaseDate.string(from: Date(timeIntervalSince1970: s))
    }

    // MARK: - C2: grantGuest optimistic + wire

    func testGrantGuestWritesStoreAndEnqueuesCreateWire() async throws {
        let store = InMemoryLocalStore()
        let outbox = InMemoryOutbox()
        let path = makePath(store: store, outbox: outbox, ids: ["guest0000000001"])

        let guest = try await path.grantGuest(deckId: "deck1", userId: "userB")
        XCTAssertEqual(guest.id, "guest0000000001", "client-minted id used")
        XCTAssertEqual(guest.deck, "deck1")
        XCTAssertEqual(guest.user, "userB")
        XCTAssertEqual(guest.grantedAt, fixedNow)

        // Optimistic mirror row present immediately.
        let stored = await store.deckGuest(id: "guest0000000001")
        XCTAssertEqual(stored?.user, "userB")

        // Exactly one create enqueued with the correct wire body (no LWW clock).
        let pending = await outbox.pending()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.type, .create)
        XCTAssertEqual(pending.first?.entity, "deck_guests")
        let body = try JSONSerialization.jsonObject(with: pending[0].payload) as? [String: Any]
        XCTAssertEqual(body?["id"] as? String, "guest0000000001")
        XCTAssertEqual(body?["deck"] as? String, "deck1")
        XCTAssertEqual(body?["user"] as? String, "userB")
        XCTAssertNotNil(body?["granted_at"] as? String)
        XCTAssertNil(body?["client_updated_at"], "deck_guests carries no LWW clock")
    }

    // MARK: - [FIX #6-iOS]: re-grant (deck,user) 400 → success

    func testDeckGuestsCreate400IsClassifiedSuccess() {
        // The composite-unique violation is keyed on relation fields, not data.id,
        // so isDuplicateIdError misses it — the entity-aware branch must catch it.
        let body = Data(#"{"data":{"deck":{"code":"validation_not_unique","message":"..."}}}"#.utf8)
        XCTAssertEqual(
            MutationSender.classify(status: 400, body: body, type: .create, entity: "deck_guests"),
            .success,
            "a deck_guests re-grant 400 is an idempotent no-op success"
        )
    }

    func testDeckGuestsCreate400EmptyBodyIsSuccess() {
        // Even with an unrecognized body shape, any deck_guests create 400 is the
        // re-grant case → success (keeps the optimistic row, surfaces no error).
        XCTAssertEqual(
            MutationSender.classify(status: 400, body: Data(), type: .create, entity: "deck_guests"),
            .success
        )
    }

    func testNonGuestCreate400StillDrops() {
        // The entity gate must not loosen the drop behavior for other collections.
        XCTAssertEqual(
            MutationSender.classify(status: 400, body: Data(), type: .create, entity: "cards"),
            .drop(status: 400)
        )
    }

    func testDeckGuestsDelete400StillDrops() {
        // Only creates are idempotent; a 400 on a guest DELETE is a real error.
        XCTAssertEqual(
            MutationSender.classify(status: 400, body: Data(), type: .delete, entity: "deck_guests"),
            .drop(status: 400)
        )
    }

    // MARK: - C3: SyncEngine guest CREATE

    func testGuestCreateForMeHydratesWhenDeckAbsent() async {
        let store = InMemoryLocalStore()
        let engine = SyncEngine(store: store, currentUserId: "me")
        let hydrated = HydrationSpy()
        await engine.setHydrationHandler { id in await hydrated.record(id) }

        let applied = await engine.apply(event("deck_guests", "create",
            #"{"id":"g1","deck":"deckX","user":"me","granted_at":"\#(wireDate(5))"}"#))
        XCTAssertTrue(applied)
        let ids1 = await hydrated.ids
        XCTAssertEqual(ids1, ["deckX"], "a grant to me for an absent deck triggers hydration")
        let stored1 = await store.deckGuest(id: "g1")
        XCTAssertNotNil(stored1, "guest row stored")
    }

    func testGuestCreateForMeSkipsHydrationWhenDeckPresentAndLive() async {
        let store = InMemoryLocalStore()
        await store.upsertDeck(Deck(id: "deckX", owner: "owner", name: "Shared", clientUpdatedAt: Date(timeIntervalSince1970: 1)))
        let engine = SyncEngine(store: store, currentUserId: "me")
        let hydrated = HydrationSpy()
        await engine.setHydrationHandler { id in await hydrated.record(id) }

        let applied = await engine.apply(event("deck_guests", "create",
            #"{"id":"g1","deck":"deckX","user":"me","granted_at":"\#(wireDate(5))"}"#))
        XCTAssertTrue(applied)
        let ids2 = await hydrated.ids
        XCTAssertEqual(ids2, [], "deck already present + live → no redundant hydration")
    }

    func testGuestCreateOwnerEchoDoesNotHydrate() async {
        let store = InMemoryLocalStore()
        let engine = SyncEngine(store: store, currentUserId: "me")
        let hydrated = HydrationSpy()
        await engine.setHydrationHandler { id in await hydrated.record(id) }

        // I (owner) granted someone ELSE — the echo's user != me.
        let applied = await engine.apply(event("deck_guests", "create",
            #"{"id":"g1","deck":"deckX","user":"friend","granted_at":"\#(wireDate(5))"}"#))
        XCTAssertTrue(applied)
        let ids3 = await hydrated.ids
        XCTAssertEqual(ids3, [], "owner echo (user != me) stores the row only, no hydration")
        let stored3 = await store.deckGuest(id: "g1")
        XCTAssertNotNil(stored3)
    }

    // MARK: - C3 / [FIX #7-iOS]: SyncEngine guest DELETE

    func testGuestDeleteForMeEvictsForeignOwnedDeck() async {
        let store = InMemoryLocalStore()
        await store.upsertDeck(Deck(id: "deckX", owner: "owner", name: "Shared", clientUpdatedAt: Date(timeIntervalSince1970: 1)))
        await store.upsertCard(Card(id: "c1", deck: "deckX", position: 1000, title: "Shot", clientUpdatedAt: Date(timeIntervalSince1970: 1)))
        await store.upsertCardImage(CardImage(id: "img1", card: "c1", position: 1, file: "f.jpg"))
        await store.upsertDeckGuest(DeckGuest(id: "g1", deck: "deckX", user: "me", grantedAt: Date()))
        let engine = SyncEngine(store: store, currentUserId: "me")

        let applied = await engine.apply(event("deck_guests", "delete", #"{"id":"g1"}"#))
        XCTAssertTrue(applied)
        let removedGuest = await store.deckGuest(id: "g1")
        XCTAssertNil(removedGuest, "guest row removed")
        // Deck is hidden (display-evicted), its cards hidden, images hard-removed.
        let deck = await store.deck(id: "deckX")
        XCTAssertNotNil(deck?.deletedAt, "foreign-owned deck hidden on revoke")
        let card = await store.card(id: "c1")
        XCTAssertNotNil(card?.deletedAt, "child card hidden")
        let image = await store.cardImage(id: "img1")
        XCTAssertNil(image, "child image evicted")
    }

    func testGuestDeleteForMeKeepsMyOwnDeck() async {
        let store = InMemoryLocalStore()
        // I own the deck — revoking a guest I granted must NOT evict my own deck.
        await store.upsertDeck(Deck(id: "deckX", owner: "me", name: "Mine", clientUpdatedAt: Date(timeIntervalSince1970: 1)))
        await store.upsertDeckGuest(DeckGuest(id: "g1", deck: "deckX", user: "me", grantedAt: Date()))
        let engine = SyncEngine(store: store, currentUserId: "me")

        let applied = await engine.apply(event("deck_guests", "delete", #"{"id":"g1"}"#))
        XCTAssertTrue(applied)
        let deck = await store.deck(id: "deckX")
        XCTAssertNil(deck?.deletedAt, "I own the deck → keep it on guest revoke")
    }

    func testGuestDeleteForSomeoneElseDoesNotEvict() async {
        let store = InMemoryLocalStore()
        await store.upsertDeck(Deck(id: "deckX", owner: "owner", name: "Shared", clientUpdatedAt: Date(timeIntervalSince1970: 1)))
        // The revoked grant was for a DIFFERENT user (not me).
        await store.upsertDeckGuest(DeckGuest(id: "g1", deck: "deckX", user: "friend", grantedAt: Date()))
        let engine = SyncEngine(store: store, currentUserId: "me")

        let applied = await engine.apply(event("deck_guests", "delete", #"{"id":"g1"}"#))
        XCTAssertTrue(applied)
        let deck = await store.deck(id: "deckX")
        XCTAssertNil(deck?.deletedAt, "a revoke of another user's grant must not evict my view")
    }

    // MARK: - C1: resolveUser(byEmail:) query shape + id != self selection

    func testResolveUserSendsEmailQueryParamNoFilterAndPicksForeignRow() async throws {
        StubURLProtocol.shared.reset()
        defer { StubURLProtocol.shared.reset() }
        // The endpoint returns the caller's own row PLUS the matched (hidden) row.
        StubURLProtocol.shared.setHandler { _ in
            let body = #"{"page":1,"perPage":200,"totalItems":2,"totalPages":1,"items":[{"id":"me","email":"owner@x","name":"Me"},{"id":"guest","email":"","name":""}]}"#
            return (200, Data(body.utf8))
        }
        let client = APIClient(baseURL: URL(string: "http://stub.local")!, session: StubURLProtocol.makeSession())
        await client.setAuthToken("tok")
        let repo = DeckGuestRepository(client: client, currentUserId: "me")

        let resolved = try await repo.resolveUser(byEmail: "guest@posedeck.test")
        XCTAssertEqual(resolved, "guest", "pick the row whose id != current user id")

        let request = try XCTUnwrap(StubURLProtocol.shared.requests.last)
        let url = try XCTUnwrap(request.url)
        let comps = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let queryNames = comps.queryItems?.map(\.name) ?? []
        XCTAssertTrue(queryNames.contains("email"), "email passed as a query param")
        XCTAssertEqual(
            comps.queryItems?.first(where: { $0.name == "email" })?.value,
            "guest@posedeck.test"
        )
        XCTAssertFalse(queryNames.contains("filter"), "must NOT add a filter clause (hidden email field would exclude the row)")
        XCTAssertTrue(url.path.hasSuffix("/api/collections/users/records"), "hits the users collection")
    }

    func testResolveUserDecodesGuestRowWithMissingEmailField() async throws {
        // Regression: live PB OMITS the email/name fields entirely on a row the
        // caller can't view (viewRule), not "". `User.email`/`name` must be
        // optional or decoding the matched guest row throws and the grant fails
        // (the bug the XCUITest surfaced).
        StubURLProtocol.shared.reset()
        defer { StubURLProtocol.shared.reset() }
        StubURLProtocol.shared.setHandler { _ in
            let body = #"{"page":1,"perPage":200,"totalItems":2,"totalPages":1,"items":[{"id":"me","email":"owner@x","name":"Me"},{"id":"guest"}]}"#
            return (200, Data(body.utf8))
        }
        let client = APIClient(baseURL: URL(string: "http://stub.local")!, session: StubURLProtocol.makeSession())
        await client.setAuthToken("tok")
        let repo = DeckGuestRepository(client: client, currentUserId: "me")

        let resolved = try await repo.resolveUser(byEmail: "guest@posedeck.test")
        XCTAssertEqual(resolved, "guest", "a guest row with no email field still resolves by id")
    }

    func testResolveUserReturnsNilWhenOnlySelfRowMatches() async throws {
        StubURLProtocol.shared.reset()
        defer { StubURLProtocol.shared.reset() }
        // A lookup of the caller's own email returns only the caller's row.
        StubURLProtocol.shared.setHandler { _ in
            let body = #"{"page":1,"perPage":200,"totalItems":1,"totalPages":1,"items":[{"id":"me","email":"owner@x","name":"Me"}]}"#
            return (200, Data(body.utf8))
        }
        let client = APIClient(baseURL: URL(string: "http://stub.local")!, session: StubURLProtocol.makeSession())
        await client.setAuthToken("tok")
        let repo = DeckGuestRepository(client: client, currentUserId: "me")

        let resolved = try await repo.resolveUser(byEmail: "owner@x")
        XCTAssertNil(resolved, "no foreign row → nil (self-share / unknown email)")
    }

    // MARK: - swift-grantGuest-dup-check-stale: GuestGrant.isDuplicate decision

    func testIsDuplicateTrueWhenPriorGrantForSameUserExists() {
        // A prior grant for the same user (different id) is in the mirror →
        // duplicate. This is the case the friendly "already shared" message
        // covers. Each real grant mints a fresh id (OfflineWritePath), so two
        // rows for the same user differ only by id.
        let prior = DeckGuest(id: "g-old", deck: "deck1", user: "userB", grantedAt: fixedNow)
        let resolved = DeckGuest(id: "g-new", deck: "deck1", user: "userB", grantedAt: fixedNow)
        XCTAssertTrue(
            GuestGrant.isDuplicate(resolved: resolved, in: [prior, resolved]),
            "a prior grant for the same user (different id) is a duplicate"
        )
    }

    func testIsDuplicateFalseWhenOnlyTheJustWrittenRowIsPresent() {
        // First-ever grant: the only row for this user is the one we just wrote,
        // excluded by id → not a duplicate (the grant should succeed quietly).
        let resolved = DeckGuest(id: "g-new", deck: "deck1", user: "userB", grantedAt: fixedNow)
        XCTAssertFalse(
            GuestGrant.isDuplicate(resolved: resolved, in: [resolved]),
            "the just-written row alone is not a duplicate of itself"
        )
    }

    func testIsDuplicateFalseForADifferentUser() {
        let other = DeckGuest(id: "g-other", deck: "deck1", user: "userC", grantedAt: fixedNow)
        let resolved = DeckGuest(id: "g-new", deck: "deck1", user: "userB", grantedAt: fixedNow)
        XCTAssertFalse(
            GuestGrant.isDuplicate(resolved: resolved, in: [other, resolved]),
            "a grant for a different user is not a duplicate"
        )
    }

    func testIsDuplicateFalseAgainstStalePreGrantSnapshotIsTheBug() {
        // ROOT CAUSE of swift-grantGuest-dup-check-stale: the OLD code checked the
        // duplicate against `guests` BEFORE reloading the mirror. Under a
        // concurrent double-grant, that snapshot can lack the first grant's row,
        // so the check misses the duplicate. Modeled here: the resolved row is a
        // duplicate, but a stale snapshot that omits the prior row returns false —
        // exactly why the fix reloads the mirror FIRST and then decides against
        // the fresh list (which DOES contain the prior row, asserted above).
        let resolved = DeckGuest(id: "g-new", deck: "deck1", user: "userB", grantedAt: fixedNow)
        let stalePreGrantSnapshot: [DeckGuest] = []  // prior grant not yet folded in
        XCTAssertFalse(
            GuestGrant.isDuplicate(resolved: resolved, in: stalePreGrantSnapshot),
            "a stale pre-grant snapshot misses the duplicate — the fix must decide against a reloaded mirror"
        )
        // The fresh mirror (post-reload) contains BOTH the prior and just-written
        // rows, so the same decision now correctly fires.
        let prior = DeckGuest(id: "g-old", deck: "deck1", user: "userB", grantedAt: fixedNow)
        XCTAssertTrue(
            GuestGrant.isDuplicate(resolved: resolved, in: [prior, resolved]),
            "deciding against the reloaded mirror correctly detects the duplicate"
        )
    }

    func testGuestDeleteWithAbsentDeckIsNoOp() async {
        let store = InMemoryLocalStore()
        await store.upsertDeckGuest(DeckGuest(id: "g1", deck: "deckGone", user: "me", grantedAt: Date()))
        let engine = SyncEngine(store: store, currentUserId: "me")

        let applied = await engine.apply(event("deck_guests", "delete", #"{"id":"g1"}"#))
        XCTAssertTrue(applied)
        let removed = await store.deckGuest(id: "g1")
        XCTAssertNil(removed, "guest row removed")
        let absent = await store.deck(id: "deckGone")
        XCTAssertNil(absent, "absent deck stays absent — no fabricated row")
    }
}

/// Records the deck ids passed to the hydration handler.
actor HydrationSpy {
    private(set) var ids: [String] = []
    func record(_ id: String) { ids.append(id) }
}
