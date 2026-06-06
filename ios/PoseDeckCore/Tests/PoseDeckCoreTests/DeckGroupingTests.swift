import XCTest
@testable import PoseDeckCore

/// Tests for the pure deck-grouping/search helpers (DESIGN.md §3.3).
final class DeckGroupingTests: XCTestCase {

    /// Fixed local calendar so the start-of-day boundary is deterministic.
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        var comps = DateComponents()
        comps.year = y; comps.month = m; comps.day = d; comps.hour = h
        return calendar.date(from: comps)!
    }

    private func deck(_ id: String, name: String = "Deck", shoot: Date? = nil) -> Deck {
        Deck(id: id, owner: "u", name: name, shootDate: shoot)
    }

    func testDeckDatedTodayIsUpcomingNotPast() {
        let now = date(2026, 6, 6, 15) // 3pm
        // Shoot earlier today (8am) — still "today", must be Upcoming.
        let todayMorning = deck("d1", shoot: date(2026, 6, 6, 8))
        let grouped = DeckGrouping.groupDecks([todayMorning], now: now, calendar: calendar)
        XCTAssertEqual(grouped.upcoming.map(\.id), ["d1"], "a deck dated today is Upcoming")
        XCTAssertTrue(grouped.past.isEmpty)
    }

    func testDeckDatedYesterdayIsPast() {
        let now = date(2026, 6, 6, 1)
        let yesterday = deck("d1", shoot: date(2026, 6, 5, 23))
        let grouped = DeckGrouping.groupDecks([yesterday], now: now, calendar: calendar)
        XCTAssertEqual(grouped.past.map(\.id), ["d1"])
        XCTAssertTrue(grouped.upcoming.isEmpty)
    }

    func testUpcomingSortedSoonestFirst() {
        let now = date(2026, 6, 6)
        let far = deck("far", shoot: date(2026, 12, 1))
        let soon = deck("soon", shoot: date(2026, 6, 10))
        let mid = deck("mid", shoot: date(2026, 8, 1))
        let grouped = DeckGrouping.groupDecks([far, soon, mid], now: now, calendar: calendar)
        XCTAssertEqual(grouped.upcoming.map(\.id), ["soon", "mid", "far"])
    }

    func testPastSortedMostRecentFirst() {
        let now = date(2026, 6, 6)
        let old = deck("old", shoot: date(2025, 1, 1))
        let recent = deck("recent", shoot: date(2026, 6, 1))
        let mid = deck("mid", shoot: date(2026, 3, 1))
        let grouped = DeckGrouping.groupDecks([old, recent, mid], now: now, calendar: calendar)
        XCTAssertEqual(grouped.past.map(\.id), ["recent", "mid", "old"])
    }

    func testUndatedSortedByNameCaseInsensitive() {
        let now = date(2026, 6, 6)
        let grouped = DeckGrouping.groupDecks([
            deck("b", name: "banana"),
            deck("a", name: "Apple"),
            deck("c", name: "cherry"),
        ], now: now, calendar: calendar)
        XCTAssertEqual(grouped.undated.map(\.name), ["Apple", "banana", "cherry"])
    }

    func testThreeWaySplit() {
        let now = date(2026, 6, 6)
        let grouped = DeckGrouping.groupDecks([
            deck("up", shoot: date(2026, 7, 1)),
            deck("un", name: "Undated one"),
            deck("pa", shoot: date(2026, 1, 1)),
        ], now: now, calendar: calendar)
        XCTAssertEqual(grouped.upcoming.map(\.id), ["up"])
        XCTAssertEqual(grouped.undated.map(\.id), ["un"])
        XCTAssertEqual(grouped.past.map(\.id), ["pa"])
    }

    // MARK: - search

    func testSearchEmptyQueryReturnsAll() {
        let decks = [deck("a", name: "Apple"), deck("b", name: "Banana")]
        XCTAssertEqual(DeckGrouping.searchDecks(decks, query: "  ").map(\.id), ["a", "b"])
    }

    func testSearchCaseInsensitiveSubstring() {
        let decks = [
            deck("a", name: "Beach Shoot"),
            deck("b", name: "Studio Portrait"),
            deck("c", name: "beachfront"),
        ]
        XCTAssertEqual(DeckGrouping.searchDecks(decks, query: "BEACH").map(\.id), ["a", "c"])
    }

    func testSearchNoMatchReturnsEmpty() {
        let decks = [deck("a", name: "Apple")]
        XCTAssertTrue(DeckGrouping.searchDecks(decks, query: "zzz").isEmpty)
    }
}
