/**
 * Pure helpers for the deck list view (DESIGN.md §3.3).
 *
 * These functions are intentionally side-effect free and take `now` as a
 * parameter so they stay deterministic and fully unit-testable.
 */
import type { Deck } from "@/lib/types";

/** The three buckets the deck list is grouped into. */
export interface GroupedDecks {
  /** shoot_date >= today, soonest first. */
  upcoming: Deck[];
  /** no shoot_date. */
  undated: Deck[];
  /** shoot_date < today, most-recent first. */
  past: Deck[];
}

/** Does a deck have a usable (non-empty, parseable) shoot date? */
function shootDateMs(deck: Deck): number | null {
  if (typeof deck.shoot_date !== "string" || deck.shoot_date === "") {
    return null;
  }
  const ms = Date.parse(deck.shoot_date);
  return Number.isNaN(ms) ? null : ms;
}

/**
 * Start-of-day (local) for the given instant, in epoch ms.
 *
 * "Today" boundary: a deck whose shoot_date falls anywhere on the current
 * calendar day counts as Upcoming (date >= today), not Past.
 */
function startOfDayMs(now: Date): number {
  return new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
}

/**
 * Group decks into Upcoming / Undated / Past per DESIGN.md §3.3.
 *
 *  - **upcoming**: `shoot_date >= start of today`, sorted soonest-first.
 *  - **undated**: no `shoot_date`, sorted by name (case-insensitive) for a
 *    stable, predictable order.
 *  - **past**: `shoot_date < start of today`, sorted most-recent-first.
 *
 * Pure: depends only on its arguments. `now` is injected by the caller.
 */
export function groupDecks(decks: Deck[], now: Date): GroupedDecks {
  const todayMs = startOfDayMs(now);

  const upcoming: Array<{ deck: Deck; ms: number }> = [];
  const undated: Deck[] = [];
  const past: Array<{ deck: Deck; ms: number }> = [];

  for (const deck of decks) {
    const ms = shootDateMs(deck);
    if (ms === null) {
      undated.push(deck);
    } else if (ms >= todayMs) {
      upcoming.push({ deck, ms });
    } else {
      past.push({ deck, ms });
    }
  }

  upcoming.sort((a, b) => a.ms - b.ms); // soonest first
  past.sort((a, b) => b.ms - a.ms); // most recent first
  undated.sort((a, b) =>
    a.name.localeCompare(b.name, undefined, { sensitivity: "base" }),
  );

  return {
    upcoming: upcoming.map((e) => e.deck),
    undated,
    past: past.map((e) => e.deck),
  };
}

/**
 * Filter decks by a case-insensitive substring match on `name`.
 *
 * An empty / whitespace-only query returns the input unchanged. Pure.
 */
export function searchDecks(decks: Deck[], query: string): Deck[] {
  const needle = query.trim().toLowerCase();
  if (needle === "") {
    return decks;
  }
  return decks.filter((deck) => deck.name.toLowerCase().includes(needle));
}
