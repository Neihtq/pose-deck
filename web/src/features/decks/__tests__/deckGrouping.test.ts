import { describe, expect, it } from "vitest";

import { groupDecks, searchDecks } from "@/features/decks/deckGrouping";
import type { Deck } from "@/lib/types";

/** Build a Deck with sensible defaults; override only what a test cares about. */
function makeDeck(overrides: Partial<Deck> & { id: string }): Deck {
  return {
    id: overrides.id,
    owner: overrides.owner ?? "user1",
    name: overrides.name ?? overrides.id,
    shoot_date: overrides.shoot_date ?? "",
    client_updated_at: overrides.client_updated_at ?? "",
    created: overrides.created ?? "2026-01-01T00:00:00Z",
    updated: overrides.updated ?? "2026-01-01T00:00:00Z",
    deleted_at: overrides.deleted_at ?? "",
  };
}

const ids = (decks: Deck[]) => decks.map((d) => d.id);

describe("groupDecks", () => {
  // Fixed reference "now" used across boundary tests: 2026-06-06 12:00 local.
  const now = new Date(2026, 5, 6, 12, 0, 0);

  it("partitions decks into upcoming / undated / past", () => {
    const decks = [
      makeDeck({ id: "future", shoot_date: "2026-07-01T09:00:00Z" }),
      makeDeck({ id: "none" }),
      makeDeck({ id: "old", shoot_date: "2026-01-01T09:00:00Z" }),
    ];
    const result = groupDecks(decks, now);
    expect(ids(result.upcoming)).toEqual(["future"]);
    expect(ids(result.undated)).toEqual(["none"]);
    expect(ids(result.past)).toEqual(["old"]);
  });

  it("sorts upcoming soonest-first", () => {
    const decks = [
      makeDeck({ id: "c", shoot_date: "2026-09-01T00:00:00Z" }),
      makeDeck({ id: "a", shoot_date: "2026-06-10T00:00:00Z" }),
      makeDeck({ id: "b", shoot_date: "2026-07-15T00:00:00Z" }),
    ];
    expect(ids(groupDecks(decks, now).upcoming)).toEqual(["a", "b", "c"]);
  });

  it("sorts past most-recent-first", () => {
    const decks = [
      makeDeck({ id: "x", shoot_date: "2026-01-01T00:00:00Z" }),
      makeDeck({ id: "z", shoot_date: "2026-05-01T00:00:00Z" }),
      makeDeck({ id: "y", shoot_date: "2026-03-01T00:00:00Z" }),
    ];
    expect(ids(groupDecks(decks, now).past)).toEqual(["z", "y", "x"]);
  });

  it("sorts undated alphabetically (case-insensitive)", () => {
    const decks = [
      makeDeck({ id: "1", name: "banana" }),
      makeDeck({ id: "2", name: "Apple" }),
      makeDeck({ id: "3", name: "cherry" }),
    ];
    expect(ids(groupDecks(decks, now).undated)).toEqual(["2", "1", "3"]);
  });

  describe("today boundary", () => {
    it("treats a shoot date earlier today as upcoming (date >= today)", () => {
      // 09:00 local today, before `now` at 12:00 — still the same calendar day.
      const earlierToday = makeDeck({
        id: "earlier",
        shoot_date: new Date(2026, 5, 6, 9, 0, 0).toISOString(),
      });
      const result = groupDecks([earlierToday], now);
      expect(ids(result.upcoming)).toEqual(["earlier"]);
      expect(result.past).toHaveLength(0);
    });

    it("treats the exact start of today as upcoming", () => {
      const startToday = makeDeck({
        id: "midnight",
        shoot_date: new Date(2026, 5, 6, 0, 0, 0).toISOString(),
      });
      expect(ids(groupDecks([startToday], now).upcoming)).toEqual(["midnight"]);
    });

    it("treats end of yesterday as past", () => {
      const lastNight = makeDeck({
        id: "yesterday",
        shoot_date: new Date(2026, 5, 5, 23, 59, 59).toISOString(),
      });
      const result = groupDecks([lastNight], now);
      expect(ids(result.past)).toEqual(["yesterday"]);
      expect(result.upcoming).toHaveLength(0);
    });
  });

  it("treats empty and unparseable shoot dates as undated", () => {
    const decks = [
      makeDeck({ id: "empty", shoot_date: "" }),
      makeDeck({ id: "garbage", shoot_date: "not-a-date" }),
    ];
    const result = groupDecks(decks, now);
    expect(ids(result.undated).sort()).toEqual(["empty", "garbage"]);
    expect(result.upcoming).toHaveLength(0);
    expect(result.past).toHaveLength(0);
  });

  it("returns empty buckets for an empty input", () => {
    const result = groupDecks([], now);
    expect(result).toEqual({ upcoming: [], undated: [], past: [] });
  });

  it("does not mutate the input array", () => {
    const decks = [
      makeDeck({ id: "b", shoot_date: "2026-09-01T00:00:00Z" }),
      makeDeck({ id: "a", shoot_date: "2026-07-01T00:00:00Z" }),
    ];
    const snapshot = ids(decks);
    groupDecks(decks, now);
    expect(ids(decks)).toEqual(snapshot);
  });
});

describe("searchDecks", () => {
  const decks = [
    makeDeck({ id: "1", name: "Smith Wedding" }),
    makeDeck({ id: "2", name: "Jones Engagement" }),
    makeDeck({ id: "3", name: "smith family portrait" }),
  ];

  it("matches case-insensitively on name", () => {
    expect(ids(searchDecks(decks, "smith"))).toEqual(["1", "3"]);
  });

  it("matches substrings anywhere in the name", () => {
    expect(ids(searchDecks(decks, "engage"))).toEqual(["2"]);
  });

  it("returns all decks for an empty or whitespace query", () => {
    expect(ids(searchDecks(decks, ""))).toEqual(["1", "2", "3"]);
    expect(ids(searchDecks(decks, "   "))).toEqual(["1", "2", "3"]);
  });

  it("trims the query before matching", () => {
    expect(ids(searchDecks(decks, "  jones  "))).toEqual(["2"]);
  });

  it("returns an empty array when nothing matches", () => {
    expect(searchDecks(decks, "zzz")).toEqual([]);
  });
});
