import { beforeEach, describe, expect, it, vi } from "vitest";

import type { Card } from "@/lib/types";

// Mock the PocketBase client wrapper so cardApi never touches the network.
const getFullList = vi.fn();
const create = vi.fn();
const update = vi.fn();

// Real PocketBase `pb.filter()` autoescapes bound values into single quotes
// (e.g. a `'` becomes `\'`). We mock that escaping behaviour so the regression
// test can assert cardApi binds values rather than raw-interpolating them.
// Defined via vi.hoisted so it exists when the (hoisted) vi.mock factory runs.
const { filter } = vi.hoisted(() => ({
  filter: vi.fn((raw: string, params?: Record<string, unknown>) =>
    raw.replace(/\{:(\w+)\}/g, (_match, key: string) => {
      const value = params?.[key];
      if (typeof value === "string") {
        return `'${value.replace(/'/g, "\\'")}'`;
      }
      return String(value);
    }),
  ),
}));

vi.mock("@/lib/pocketbase", () => ({
  collections: {
    cards: () => ({ getFullList, create, update }),
  },
  pb: { filter },
}));

import {
  POSITION_GAP,
  computeReorderedPositions,
  createCard,
  listCards,
  nextPosition,
  reorderCards,
} from "@/features/cards/cardApi";

function makeCard(id: string, position: number): Card {
  return {
    id,
    deck: "deck1",
    position,
    title: id,
    time_slot: "",
    subjects: "",
    direction: "",
    notes: "",
    client_updated_at: "",
    created: "",
    updated: "",
    deleted_at: "",
  };
}

beforeEach(() => {
  getFullList.mockReset();
  create.mockReset();
  update.mockReset();
  filter.mockClear();
});

describe("listCards (filter binding)", () => {
  // Regression (finding SEC-1): the deck id comes from a URL route param
  // (useParams) and is attacker-controllable. It MUST be bound via
  // `pb.filter()` rather than string-interpolated into the filter, so a quote
  // in the value cannot break out of the literal and corrupt the query.
  it("binds the deck id via pb.filter instead of raw interpolation", async () => {
    getFullList.mockResolvedValue([]);

    await listCards('x" || deleted_at != ""');

    // The dynamic value must be passed as a bound param, not concatenated.
    expect(filter).toHaveBeenCalledTimes(1);
    const [raw, params] = filter.mock.calls[0];
    expect(raw).toContain("{:deck}");
    expect(params).toEqual({ deck: 'x" || deleted_at != ""' });

    // The filter handed to the SDK must be the *escaped* result, never the
    // raw user string spliced directly into the clause.
    const builtFilter = getFullList.mock.calls[0][0].filter;
    expect(builtFilter).not.toContain('deck = "x" || deleted_at != ""');
    expect(builtFilter).toContain("deleted_at = ''");
  });
});

describe("nextPosition (pure)", () => {
  it("returns POSITION_GAP for an empty deck", () => {
    expect(nextPosition([])).toBe(POSITION_GAP);
  });

  it("returns last position + POSITION_GAP", () => {
    expect(nextPosition([{ position: 1000 }, { position: 2000 }])).toBe(3000);
  });

  it("uses the max position regardless of order", () => {
    expect(nextPosition([{ position: 5000 }, { position: 1000 }])).toBe(6000);
  });
});

describe("computeReorderedPositions (pure)", () => {
  it("assigns clean integer gaps in order", () => {
    expect(computeReorderedPositions(["a", "b", "c"])).toEqual([
      { id: "a", position: 1000 },
      { id: "b", position: 2000 },
      { id: "c", position: 3000 },
    ]);
  });

  it("returns an empty array for no ids", () => {
    expect(computeReorderedPositions([])).toEqual([]);
  });
});

describe("createCard", () => {
  it("computes position from existing cards and stamps fields", async () => {
    getFullList.mockResolvedValue([makeCard("a", 1000), makeCard("b", 2000)]);
    create.mockResolvedValue(makeCard("c", 3000));

    await createCard("deck1", { title: "New shot" });

    expect(create).toHaveBeenCalledTimes(1);
    const payload = create.mock.calls[0][0];
    expect(payload.deck).toBe("deck1");
    expect(payload.position).toBe(3000);
    expect(payload.title).toBe("New shot");
    expect(payload.time_slot).toBe("");
    expect(payload.deleted_at).toBe("");
    expect(typeof payload.client_updated_at).toBe("string");
    expect(payload.client_updated_at).not.toBe("");
  });

  it("starts at POSITION_GAP for an empty deck", async () => {
    getFullList.mockResolvedValue([]);
    create.mockResolvedValue(makeCard("first", 1000));

    await createCard("deck1", { title: "First" });

    expect(create.mock.calls[0][0].position).toBe(POSITION_GAP);
  });
});

describe("reorderCards", () => {
  it("restripes positions and updates each card", async () => {
    update.mockResolvedValue(makeCard("x", 0));

    await reorderCards("deck1", ["c", "a", "b"]);

    expect(update).toHaveBeenCalledTimes(3);
    expect(update.mock.calls[0][0]).toBe("c");
    expect(update.mock.calls[0][1].position).toBe(1000);
    expect(update.mock.calls[1][0]).toBe("a");
    expect(update.mock.calls[1][1].position).toBe(2000);
    expect(update.mock.calls[2][0]).toBe("b");
    expect(update.mock.calls[2][1].position).toBe(3000);
    // Every update stamps client_updated_at.
    for (const call of update.mock.calls) {
      expect(call[1].client_updated_at).toBeTruthy();
    }
  });

  // Regression (finding C5): a reorder must not re-write/re-stamp cards whose
  // position did not change. Re-stamping client_updated_at on unmoved cards can
  // clobber a concurrent edit's ordering metadata under last-write-wins
  // (ARCHITECTURE.md §4.3).
  it("skips cards whose position did not change", async () => {
    update.mockResolvedValue(makeCard("x", 0));

    // Cards a, b, c currently at 1000, 2000, 3000. Moving only "c" ahead of "b"
    // changes b -> 3000 and c -> 2000, but leaves "a" at 1000 untouched.
    const currentPositions = new Map([
      ["a", 1000],
      ["b", 2000],
      ["c", 3000],
    ]);

    await reorderCards("deck1", ["a", "c", "b"], currentPositions);

    // Only the two moved cards are written; "a" (unchanged at 1000) is skipped.
    expect(update).toHaveBeenCalledTimes(2);
    const writtenIds = update.mock.calls.map((call) => call[0]);
    expect(writtenIds).not.toContain("a");
    expect(writtenIds.sort()).toEqual(["b", "c"]);
  });

  it("writes nothing when the order is unchanged", async () => {
    update.mockResolvedValue(makeCard("x", 0));

    const currentPositions = new Map([
      ["a", 1000],
      ["b", 2000],
      ["c", 3000],
    ]);

    await reorderCards("deck1", ["a", "b", "c"], currentPositions);

    expect(update).not.toHaveBeenCalled();
  });

  it("accepts a plain object of current positions", async () => {
    update.mockResolvedValue(makeCard("x", 0));

    await reorderCards("deck1", ["a", "c", "b"], {
      a: 1000,
      b: 2000,
      c: 3000,
    });

    const writtenIds = update.mock.calls.map((call) => call[0]);
    expect(writtenIds).not.toContain("a");
    expect(update).toHaveBeenCalledTimes(2);
  });
});
