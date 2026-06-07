import XCTest
@testable import PoseDeckCore

/// Coverage for the per-entity LWW rule (``LWW``) and ``InMemoryLocalStore``
/// (M3 plan, STEP 8 / invariant #3): decks/cards key on `client_updated_at`,
/// completions on `changed_at`, images/guests have no clock (insert / hard
/// delete).
final class LocalStoreTests: XCTestCase {

    private func t(_ s: TimeInterval) -> Date { Date(timeIntervalSince1970: s) }

    // MARK: - LWW truth table

    func testLWWAppliesWhenNoExisting() {
        let deck = Deck(id: "d", owner: "u", name: "n", clientUpdatedAt: t(1))
        XCTAssertTrue(LWW.shouldApply(incoming: deck, over: nil))
    }

    func testLWWAppliesStrictlyNewerForDeck() {
        let old = Deck(id: "d", owner: "u", name: "old", clientUpdatedAt: t(1))
        let new = Deck(id: "d", owner: "u", name: "new", clientUpdatedAt: t(2))
        XCTAssertTrue(LWW.shouldApply(incoming: new, over: old))
        XCTAssertFalse(LWW.shouldApply(incoming: old, over: new), "older loses")
    }

    func testLWWTieIsSkipped() {
        let a = Deck(id: "d", owner: "u", name: "a", clientUpdatedAt: t(5))
        let b = Deck(id: "d", owner: "u", name: "b", clientUpdatedAt: t(5))
        XCTAssertFalse(LWW.shouldApply(incoming: b, over: a), "equal clocks skip (no churn)")
    }

    func testLWWNilClockAppliesAnyway() {
        // A server row that never carried client_updated_at → apply.
        let withClock = Deck(id: "d", owner: "u", name: "local", clientUpdatedAt: t(9))
        let noClock = Deck(id: "d", owner: "u", name: "server", clientUpdatedAt: nil)
        XCTAssertTrue(LWW.shouldApply(incoming: noClock, over: withClock))
    }

    func testCompletionKeysOnChangedAt() {
        let old = CardCompletion(id: "x", card: "c", user: "u", state: .pending, changedAt: t(1))
        let new = CardCompletion(id: "x", card: "c", user: "u", state: .done, changedAt: t(2))
        XCTAssertTrue(LWW.shouldApply(incoming: new, over: old))
        XCTAssertFalse(LWW.shouldApply(incoming: old, over: new))
    }

    func testImageHasNoOrderingClock() {
        let img = CardImage(id: "i", card: "c", position: 1, file: "a.jpg", created: t(1))
        XCTAssertNil(img.orderingTimestamp)
    }

    func testGuestHasNoOrderingClock() {
        let g = DeckGuest(id: "g", deck: "d", user: "u", grantedAt: t(1))
        XCTAssertNil(g.orderingTimestamp)
    }

    // MARK: - InMemoryLocalStore

    func testDeckUpsertHonorsLWW() async {
        let store = InMemoryLocalStore()
        await store.upsertDeck(Deck(id: "d", owner: "u", name: "v2", clientUpdatedAt: t(2)))
        await store.upsertDeck(Deck(id: "d", owner: "u", name: "v1", clientUpdatedAt: t(1)))
        let result = await store.deck(id: "d")
        XCTAssertEqual(result?.name, "v2", "older write must not clobber newer")
    }

    func testCardsScopedToDeckAndSortedByPosition() async {
        let store = InMemoryLocalStore()
        await store.upsertCard(Card(id: "c2", deck: "d", position: 2000, title: "b", clientUpdatedAt: t(1)))
        await store.upsertCard(Card(id: "c1", deck: "d", position: 1000, title: "a", clientUpdatedAt: t(1)))
        await store.upsertCard(Card(id: "c3", deck: "other", position: 1, title: "z", clientUpdatedAt: t(1)))
        let cards = await store.cards(deckId: "d")
        XCTAssertEqual(cards.map(\.id), ["c1", "c2"], "scoped to deck, sorted by position")
    }

    func testImageInsertByIdNotOverwritten() async {
        let store = InMemoryLocalStore()
        let original = CardImage(id: "i", card: "c", position: 1, file: "real.jpg", created: t(1))
        await store.upsertCardImage(original)
        // An echo lacking the filename must NOT clobber the present local row.
        await store.upsertCardImage(CardImage(id: "i", card: "c", position: 1, file: nil, created: t(1)))
        let result = await store.cardImage(id: "i")
        XCTAssertEqual(result?.file, "real.jpg", "present image row wins over a byte-less echo")
    }

    func testImageHardDelete() async {
        let store = InMemoryLocalStore()
        await store.upsertCardImage(CardImage(id: "i", card: "c", position: 1, file: "x.jpg"))
        await store.hardDeleteCardImage(id: "i")
        let result = await store.cardImage(id: "i")
        XCTAssertNil(result)
    }

    func testGuestHardDeleteOnRevoke() async {
        let store = InMemoryLocalStore()
        await store.upsertDeckGuest(DeckGuest(id: "g", deck: "d", user: "u", grantedAt: t(1)))
        await store.hardDeleteDeckGuest(id: "g")
        let guests = await store.deckGuests(deckId: "d")
        XCTAssertTrue(guests.isEmpty)
    }
}
