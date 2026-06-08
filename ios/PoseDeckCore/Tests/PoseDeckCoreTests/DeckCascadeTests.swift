import XCTest
@testable import PoseDeckCore

/// Regression coverage for the deck restore cascade predicate (M3 iOS gauntlet).
///
/// The optimistic `MirrorDeckRepository.restoreDeck` previously un-hid *every*
/// trashed child (`where card.deletedAt != nil`), which resurrected a card the
/// user had individually trashed before the deck was trashed. The shared
/// ``DeckCascade/childIdsToUnhideOnRestore(cards:hiddenAt:)`` rule fixes that:
/// only children whose `deletedAt` matches the deck's prior `deletedAt` are
/// un-hidden, matching ``SyncEngine``'s realtime cascade.
final class DeckCascadeTests: XCTestCase {

    private func card(_ id: String, deletedAt: Date?) -> Card {
        Card(
            id: id, deck: "d1", position: 1000, title: id,
            timeSlot: nil, subjects: nil, direction: nil, notes: nil,
            clientUpdatedAt: Date(timeIntervalSince1970: 1_000), created: nil,
            updated: nil, deletedAt: deletedAt
        )
    }

    func testUnhidesOnlyChildrenHiddenByTheDeckCascade() {
        let deckHiddenAt = Date(timeIntervalSince1970: 5_000)
        let individuallyTrashedAt = Date(timeIntervalSince1970: 4_000)

        let cards = [
            card("live", deletedAt: nil),                       // never hidden
            card("byCascade", deletedAt: deckHiddenAt),         // hidden by deck delete
            card("individually", deletedAt: individuallyTrashedAt), // user-trashed earlier
        ]

        let toUnhide = DeckCascade.childIdsToUnhideOnRestore(cards: cards, hiddenAt: deckHiddenAt)

        XCTAssertEqual(toUnhide, ["byCascade"],
            "only the cascade-hidden child is restored; the individually-trashed card stays trashed and a live card is untouched")
    }

    func testNilHiddenAtUnhidesNothing() {
        let cards = [card("a", deletedAt: Date(timeIntervalSince1970: 9_000))]
        XCTAssertEqual(DeckCascade.childIdsToUnhideOnRestore(cards: cards, hiddenAt: nil), [])
    }

    func testPreservesInputOrder() {
        let h = Date(timeIntervalSince1970: 7_000)
        let cards = [
            card("c3", deletedAt: h),
            card("skip", deletedAt: Date(timeIntervalSince1970: 6_999)),
            card("c1", deletedAt: h),
        ]
        XCTAssertEqual(DeckCascade.childIdsToUnhideOnRestore(cards: cards, hiddenAt: h), ["c3", "c1"])
    }

    /// Regression (CORR-IOS-1): a deck soft-deleted OFFLINE stamps the deck row
    /// and every cascade-hidden child with the SAME in-memory `now()`. If that
    /// stamp carries sub-millisecond precision, a later realtime deck-update echo
    /// for the same delete (re-delivered, or arriving after the 10s echo-suppression
    /// TTL) upserts the deck row at the wire's millisecond precision — and because
    /// `DateFormatter` *rounds* sub-ms fractions, that ms value is frequently
    /// strictly greater than the offline stamp, so LWW admits the echo and the
    /// deck row's `deletedAt` diverges from the children's. On restore, the cascade
    /// (exact `deletedAt == priorDeletedAt`) then finds NO child to un-hide and the
    /// deck restores with every card still hidden — a silent data-visibility loss.
    ///
    /// The fix stamps the offline delete at the SAME wire precision the echo will
    /// carry (`OfflineWritePath.softDeleteDeck` round-trips `now()` through
    /// `PocketBaseDate`), so deck and child `deletedAt` stay equal regardless of
    /// which path last wrote the deck row, and the restore cascade un-hides the
    /// child. This drives the full chain through the real `OfflineWritePath` +
    /// `SyncEngine` and asserts the child is visible after restore.
    func testOfflineSoftDeleteSurvivesMsRoundedEchoThenRestoresChildren() async throws {
        let store = InMemoryLocalStore()

        // A `now()` with a sub-ms fraction (.0006s past a whole second) that the
        // wire format rounds UP to .001 — empirically the bug-triggering case.
        let rawNow = Date(timeIntervalSince1970: 1_700_000_000.0006)
        let deck = Deck(id: "d1", owner: "u", name: "Shoot",
                        clientUpdatedAt: Date(timeIntervalSince1970: 1))
        await store.upsertDeck(deck)
        await store.upsertCard(Card(id: "c1", deck: "d1", position: 1000, title: "a",
                                    clientUpdatedAt: Date(timeIntervalSince1970: 1)))

        let outbox = InMemoryOutbox()
        let path = OfflineWritePath(store: store, outbox: outbox,
                                    now: { rawNow }, newId: { "unused" })

        // Soft-delete offline: stamps the deck + hides the child.
        try await path.softDeleteDeck(deck)
        let hiddenDeck = await store.deck(id: "d1")
        let hiddenChild = await store.card(id: "c1")
        XCTAssertNotNil(hiddenDeck?.deletedAt)
        XCTAssertNotNil(hiddenChild?.deletedAt, "child hidden by the cascade")

        // The realtime echo for that same delete carries the deck's deleted_at at
        // the wire's millisecond precision (what the server stored from our offline
        // PATCH). Its client_updated_at is bumped (a re-delivery / out-of-TTL echo
        // can arrive with a fresher server-side clock) so it wins LWW and re-upserts
        // the deck row. The echo never touches cards (web parity: the server
        // soft-deletes only the deck row).
        let echoDeletedAt = PocketBaseDate.string(from: rawNow) // ms-precision wire value
        let echoClock = PocketBaseDate.string(from: rawNow.addingTimeInterval(1))
        let engine = SyncEngine(store: store)
        let applied = await engine.apply(RealtimeClient.RecordEvent(
            subscription: "decks", action: "update",
            recordJSON: Data(#"{"id":"d1","owner":"u","name":"Shoot","client_updated_at":"\#(echoClock)","deleted_at":"\#(echoDeletedAt)"}"#.utf8)))
        XCTAssertTrue(applied, "the re-delivered echo carries a fresher clock and wins LWW, re-upserting the deck row at wire (ms) precision")

        // With the fix, the offline stamp already equals the wire round-trip, so
        // the deck row's deleted_at still equals the (unchanged) child's deleted_at.
        let echoedDeck = await store.deck(id: "d1")
        let childAfterEcho = await store.card(id: "c1")
        XCTAssertEqual(echoedDeck?.deletedAt, childAfterEcho?.deletedAt,
            "deck and child deleted_at stay equal across the offline + echo paths (the fix)")

        // Now restore the deck via the realtime restore echo (deleted_at cleared,
        // newer clock). The cascade must un-hide the cascade-hidden child.
        let restoreClock = PocketBaseDate.string(from: Date(timeIntervalSince1970: 1_700_000_100))
        let restored = await engine.apply(RealtimeClient.RecordEvent(
            subscription: "decks", action: "update",
            recordJSON: Data(#"{"id":"d1","owner":"u","name":"Shoot","client_updated_at":"\#(restoreClock)","deleted_at":""}"#.utf8)))
        XCTAssertTrue(restored, "restore echo wins LWW")

        let restoredChild = await store.card(id: "c1")
        XCTAssertNil(restoredChild?.deletedAt,
            "the cascade-hidden child is un-hidden on deck restore — not orphaned by the ms-precision mismatch")
    }
}
