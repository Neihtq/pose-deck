import XCTest
@testable import PoseDeckCore

/// Coverage for ``PrecachePlan`` (M3 plan, STEP 10): the 48-hour window
/// boundary, the pinned union, exclusions, and the next-refresh date math.
final class PrecachePlanTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private func at(_ offsetHours: Double) -> Date {
        now.addingTimeInterval(offsetHours * 3600)
    }

    private func deck(_ id: String, shoot: Date? = nil, deleted: Bool = false) -> Deck {
        Deck(id: id, owner: "u", name: id, shootDate: shoot, deletedAt: deleted ? now : nil)
    }

    // MARK: - 48h window

    func testWithinWindowIsIncluded() {
        let decks = [deck("a", shoot: at(47))]
        XCTAssertEqual(PrecachePlan.decksToPrecache(decks: decks, now: now), ["a"])
    }

    func testExactlyAtWindowBoundaryIsIncluded() {
        // 48h boundary is inclusive.
        let decks = [deck("a", shoot: at(48))]
        XCTAssertEqual(PrecachePlan.decksToPrecache(decks: decks, now: now), ["a"])
    }

    func testJustPastWindowBoundaryIsExcluded() {
        let decks = [deck("a", shoot: at(48.001))]
        XCTAssertEqual(PrecachePlan.decksToPrecache(decks: decks, now: now), [])
    }

    func testShootInThePastIsExcluded() {
        let decks = [deck("a", shoot: at(-1))]
        XCTAssertEqual(PrecachePlan.decksToPrecache(decks: decks, now: now), [])
    }

    func testShootExactlyNowIsIncluded() {
        let decks = [deck("a", shoot: now)]
        XCTAssertEqual(PrecachePlan.decksToPrecache(decks: decks, now: now), ["a"])
    }

    func testNoShootDateIsExcludedUnlessPinned() {
        let decks = [deck("a", shoot: nil)]
        XCTAssertEqual(PrecachePlan.decksToPrecache(decks: decks, now: now), [])
    }

    // MARK: - Pinned union

    func testPinnedAlwaysIncludedRegardlessOfDate() {
        let decks = [deck("a", shoot: at(1000)), deck("b", shoot: nil)]
        let result = PrecachePlan.decksToPrecache(
            decks: decks, pinnedIds: ["a", "b"], now: now
        )
        XCTAssertEqual(result, ["a", "b"])
    }

    func testPinnedUnionWithWindowDeduplicates() {
        // 'a' qualifies by both window AND pin → appears once, not twice.
        let decks = [deck("a", shoot: at(10)), deck("b", shoot: at(200))]
        let result = PrecachePlan.decksToPrecache(
            decks: decks, pinnedIds: ["a"], now: now
        )
        XCTAssertEqual(result, ["a"])
    }

    // MARK: - Exclusions

    func testSoftDeletedNeverPrecachedEvenWhenPinned() {
        let decks = [deck("a", shoot: at(10), deleted: true)]
        let result = PrecachePlan.decksToPrecache(
            decks: decks, pinnedIds: ["a"], now: now
        )
        XCTAssertEqual(result, [])
    }

    func testExplicitExclusionWins() {
        let decks = [deck("a", shoot: at(10))]
        let result = PrecachePlan.decksToPrecache(
            decks: decks, pinnedIds: ["a"], now: now, excluding: ["a"]
        )
        XCTAssertEqual(result, [])
    }

    func testResultPreservesInputOrder() {
        let decks = [deck("c", shoot: at(1)), deck("a", shoot: at(2)), deck("b", shoot: at(3))]
        XCTAssertEqual(PrecachePlan.decksToPrecache(decks: decks, now: now), ["c", "a", "b"])
    }

    // MARK: - nextRefreshDate

    func testNextRefreshPicksEarliestFutureShoot() {
        let decks = [deck("a", shoot: at(10)), deck("b", shoot: at(5)), deck("c", shoot: at(20))]
        XCTAssertEqual(PrecachePlan.nextRefreshDate(decks: decks, now: now), at(5))
    }

    func testNextRefreshIgnoresPastAndDeletedShoots() {
        let decks = [deck("a", shoot: at(-5)), deck("b", shoot: at(8), deleted: true), deck("c", shoot: at(12))]
        XCTAssertEqual(PrecachePlan.nextRefreshDate(decks: decks, now: now), at(12))
    }

    func testNextRefreshClampsToMinInterval() {
        // A shoot 10 minutes out is floored to the 1h minimum interval.
        let decks = [deck("a", shoot: now.addingTimeInterval(600))]
        let result = PrecachePlan.nextRefreshDate(decks: decks, now: now, minInterval: 3600)
        XCTAssertEqual(result, now.addingTimeInterval(3600))
    }

    func testNextRefreshFallsBackToDefaultIntervalWhenNoShoots() {
        let decks = [deck("a", shoot: nil)]
        let result = PrecachePlan.nextRefreshDate(decks: decks, now: now, defaultInterval: 24 * 3600)
        XCTAssertEqual(result, now.addingTimeInterval(24 * 3600))
    }
}
