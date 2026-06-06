import Foundation

/// Pure helpers for the deck list view (DESIGN.md §3.3).
///
/// Side-effect free and deterministic: `now` is injected by the caller so these
/// stay fully unit-testable. Mirrors the web `deckGrouping.ts` reference.
public enum DeckGrouping {

    /// The three buckets the deck list is grouped into (DESIGN.md §3.3).
    public struct GroupedDecks: Equatable, Sendable {
        /// `shoot_date >= start of today`, soonest first.
        public var upcoming: [Deck]
        /// No `shoot_date`, sorted by name (case-insensitive).
        public var undated: [Deck]
        /// `shoot_date < start of today`, most-recent first.
        public var past: [Deck]

        public init(upcoming: [Deck] = [], undated: [Deck] = [], past: [Deck] = []) {
            self.upcoming = upcoming
            self.undated = undated
            self.past = past
        }
    }

    /// Start-of-day (local calendar) for `now`.
    ///
    /// "Today" boundary: a deck whose `shootDate` falls anywhere on the current
    /// calendar day counts as Upcoming (date >= today), not Past — mirroring the
    /// web fix. Uses the supplied `calendar` (defaults to the current local
    /// calendar) so the boundary is local-time-correct.
    static func startOfDay(_ now: Date, calendar: Calendar = .current) -> Date {
        calendar.startOfDay(for: now)
    }

    /// Group decks into Upcoming / Undated / Past per DESIGN.md §3.3.
    ///
    ///  - **upcoming**: `shootDate >= start of today`, sorted soonest-first.
    ///  - **undated**: no `shootDate`, sorted by name (case-insensitive) for a
    ///    stable, predictable order.
    ///  - **past**: `shootDate < start of today`, sorted most-recent-first.
    ///
    /// Pure: depends only on its arguments. `now` is injected by the caller.
    public static func groupDecks(
        _ decks: [Deck],
        now: Date,
        calendar: Calendar = .current
    ) -> GroupedDecks {
        let today = startOfDay(now, calendar: calendar)

        var upcoming: [Deck] = []
        var undated: [Deck] = []
        var past: [Deck] = []

        for deck in decks {
            guard let shootDate = deck.shootDate else {
                undated.append(deck)
                continue
            }
            if shootDate >= today {
                upcoming.append(deck)
            } else {
                past.append(deck)
            }
        }

        // soonest first; deterministic tie-break by id for stability.
        upcoming.sort { lhs, rhs in
            let l = lhs.shootDate ?? .distantFuture
            let r = rhs.shootDate ?? .distantFuture
            if l != r { return l < r }
            return lhs.id < rhs.id
        }
        // most recent first; deterministic tie-break by id.
        past.sort { lhs, rhs in
            let l = lhs.shootDate ?? .distantPast
            let r = rhs.shootDate ?? .distantPast
            if l != r { return l > r }
            return lhs.id < rhs.id
        }
        // case-insensitive by name; deterministic tie-break by id.
        undated.sort { lhs, rhs in
            let cmp = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if cmp != .orderedSame { return cmp == .orderedAscending }
            return lhs.id < rhs.id
        }

        return GroupedDecks(upcoming: upcoming, undated: undated, past: past)
    }

    /// Filter decks by a case-insensitive substring match on `name`.
    ///
    /// An empty / whitespace-only query returns the input unchanged. Pure.
    public static func searchDecks(_ decks: [Deck], query: String) -> [Deck] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if needle.isEmpty { return decks }
        return decks.filter { deck in
            deck.name.range(of: needle, options: .caseInsensitive) != nil
        }
    }
}
