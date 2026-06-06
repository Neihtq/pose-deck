import XCTest
@testable import PoseDeckCore

/// Edge cases for `DeckGrouping` beyond the happy-path splits: empty input,
/// single-bucket inputs, deterministic tie-breaks on equal shoot dates / equal
/// names, the exact start-of-day boundary instant, and search trimming.
final class DeckGroupingEdgeCaseTests: XCTestCase {

    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0, _ s: Int = 0) -> Date {
        var comps = DateComponents()
        comps.year = y; comps.month = m; comps.day = d
        comps.hour = h; comps.minute = min; comps.second = s
        return calendar.date(from: comps)!
    }

    private func deck(_ id: String, name: String = "Deck", shoot: Date? = nil) -> Deck {
        Deck(id: id, owner: "u", name: name, shootDate: shoot)
    }

    func testEmptyInputYieldsThreeEmptyBuckets() {
        let grouped = DeckGrouping.groupDecks([], now: date(2026, 6, 6), calendar: calendar)
        XCTAssertEqual(grouped, DeckGrouping.GroupedDecks(), "empty input -> all buckets empty")
    }

    func testAllUndatedWhenNoShootDates() {
        let grouped = DeckGrouping.groupDecks([
            deck("a", name: "Zed"),
            deck("b", name: "alpha"),
        ], now: date(2026, 6, 6), calendar: calendar)
        XCTAssertTrue(grouped.upcoming.isEmpty)
        XCTAssertTrue(grouped.past.isEmpty)
        XCTAssertEqual(grouped.undated.map(\.id), ["b", "a"], "undated sorted case-insensitively by name")
    }

    /// The exact start-of-day instant (midnight) must classify as Upcoming, since
    /// the boundary is `shootDate >= startOfToday` (inclusive).
    func testStartOfDayBoundaryIsUpcoming() {
        let now = date(2026, 6, 6, 15)
        let atMidnight = deck("mid", shoot: date(2026, 6, 6, 0, 0, 0))
        let grouped = DeckGrouping.groupDecks([atMidnight], now: now, calendar: calendar)
        XCTAssertEqual(grouped.upcoming.map(\.id), ["mid"],
                       "a shoot at exactly start-of-today is Upcoming, not Past")
    }

    /// One second before start-of-today is Past.
    func testJustBeforeMidnightYesterdayIsPast() {
        let now = date(2026, 6, 6, 15)
        let lastNight = deck("ln", shoot: date(2026, 6, 5, 23, 59, 59))
        let grouped = DeckGrouping.groupDecks([lastNight], now: now, calendar: calendar)
        XCTAssertEqual(grouped.past.map(\.id), ["ln"])
    }

    func testUpcomingTieBreaksByIdWhenSameShootDate() {
        let now = date(2026, 6, 6)
        let same = date(2026, 7, 1, 9)
        let grouped = DeckGrouping.groupDecks([
            deck("z", shoot: same),
            deck("a", shoot: same),
            deck("m", shoot: same),
        ], now: now, calendar: calendar)
        XCTAssertEqual(grouped.upcoming.map(\.id), ["a", "m", "z"],
                       "equal shoot dates break ties by id for stable order")
    }

    func testPastTieBreaksByIdWhenSameShootDate() {
        let now = date(2026, 6, 6)
        let same = date(2026, 1, 1, 9)
        let grouped = DeckGrouping.groupDecks([
            deck("z", shoot: same),
            deck("a", shoot: same),
        ], now: now, calendar: calendar)
        XCTAssertEqual(grouped.past.map(\.id), ["a", "z"])
    }

    func testUndatedTieBreaksByIdWhenSameName() {
        let now = date(2026, 6, 6)
        let grouped = DeckGrouping.groupDecks([
            deck("z", name: "Same"),
            deck("a", name: "same"),
        ], now: now, calendar: calendar)
        XCTAssertEqual(grouped.undated.map(\.id), ["a", "z"],
                       "equal (case-insensitive) names break ties by id")
    }

    func testGroupingDoesNotMutateOrDropDecks() {
        let now = date(2026, 6, 6)
        let input = [
            deck("up", shoot: date(2026, 7, 1)),
            deck("pa", shoot: date(2025, 1, 1)),
            deck("un1"),
            deck("un2"),
        ]
        let g = DeckGrouping.groupDecks(input, now: now, calendar: calendar)
        XCTAssertEqual(g.upcoming.count + g.undated.count + g.past.count, input.count,
                       "every deck lands in exactly one bucket")
    }

    func testSearchTrimsSurroundingWhitespaceBeforeMatching() {
        let decks = [deck("a", name: "Beach"), deck("b", name: "Studio")]
        XCTAssertEqual(DeckGrouping.searchDecks(decks, query: "  beach  ").map(\.id), ["a"],
                       "query whitespace is trimmed before matching")
    }
}
