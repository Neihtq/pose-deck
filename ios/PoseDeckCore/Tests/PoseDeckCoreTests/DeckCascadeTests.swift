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
}
