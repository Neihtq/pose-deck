import { beforeEach, describe, expect, it, vi } from "vitest";

import type { Deck } from "@/lib/types";

// Mock the PocketBase client wrapper so deckApi never touches the network.
const getOne = vi.fn();
const getFirstListItem = vi.fn();
const getFullList = vi.fn();
const create = vi.fn();
const cardsGetFullList = vi.fn();
const cardsCreate = vi.fn();

// Mirror PocketBase's `pb.filter()` autoescaping so the binding-based filters
// (finding SEC-1) build a real, escaped clause in these tests. Defined via
// vi.hoisted so it exists when the (hoisted) vi.mock factory runs.
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
    decks: () => ({ getOne, getFirstListItem, getFullList, create }),
    cards: () => ({ getFullList: cardsGetFullList, create: cardsCreate }),
  },
  pb: { authStore: { record: { id: "user1" } }, filter },
}));

import { duplicateDeck, getDeck } from "@/features/decks/deckApi";

function makeDeck(id: string, deletedAt: string): Deck {
  return {
    id,
    owner: "user1",
    name: id,
    shoot_date: "",
    deleted_at: deletedAt,
    client_updated_at: "",
    created: "",
    updated: "",
  } as Deck;
}

beforeEach(() => {
  getOne.mockReset();
  getFirstListItem.mockReset();
  getFullList.mockReset();
  create.mockReset();
  cardsGetFullList.mockReset();
  cardsCreate.mockReset();
  filter.mockClear();
});

describe("getDeck (soft-delete leak regression, finding C1)", () => {
  it("scopes the fetch with deleted_at = \"\" so trashed decks read as not-found", async () => {
    getFirstListItem.mockResolvedValue(makeDeck("deck1", ""));

    const deck = await getDeck("deck1");

    // Must not use the unscoped single-record fetch, which would return a
    // soft-deleted deck and let a direct URL render/edit it.
    expect(getOne).not.toHaveBeenCalled();
    expect(getFirstListItem).toHaveBeenCalledTimes(1);
    const builtFilter = getFirstListItem.mock.calls[0][0] as string;
    expect(builtFilter).toContain("id = 'deck1'");
    expect(builtFilter).toContain("deleted_at = ''");
    expect(deck.id).toBe("deck1");
  });

  // Regression (finding SEC-1): the deck id comes from a URL route param
  // (useParams) and is attacker-controllable. It MUST be bound via
  // `pb.filter()` rather than string-interpolated into the filter clause.
  it("binds the id via pb.filter instead of raw interpolation", async () => {
    getFirstListItem.mockResolvedValue(makeDeck("deck1", ""));

    await getDeck('x" || deleted_at != ""');

    expect(filter).toHaveBeenCalled();
    const filterCall = filter.mock.calls.find(([raw]) => raw.includes("id ="));
    expect(filterCall).toBeDefined();
    const [raw, params] = filterCall!;
    expect(raw).toContain("{:id}");
    expect(params).toEqual({ id: 'x" || deleted_at != ""' });

    const builtFilter = getFirstListItem.mock.calls[0][0] as string;
    expect(builtFilter).not.toContain('id = "x" || deleted_at != ""');
    expect(builtFilter).toContain("deleted_at = ''");
  });

  it("propagates not-found when a soft-deleted deck is requested by id", async () => {
    // PocketBase getFirstListItem rejects (404) when the filtered query has no
    // match — i.e. the deck exists but is in Trash. DeckDetailPage surfaces
    // this as "Deck not found." rather than rendering an editable trashed deck.
    const notFound = new Error("The requested resource wasn't found.");
    getFirstListItem.mockRejectedValue(notFound);

    await expect(getDeck("trashed")).rejects.toThrow(notFound);
    expect(getOne).not.toHaveBeenCalled();
  });
});

describe("duplicateDeck (soft-deleted source guard, finding C2)", () => {
  it("refuses to duplicate a soft-deleted source deck and creates no copy", async () => {
    // Even if the source read resolves a trashed deck (e.g. getDeck scoping is
    // weakened in a future refactor), duplicateDeck must not resurrect it into
    // a fresh live deck outside the restore workflow.
    getFirstListItem.mockResolvedValue(makeDeck("deck1", "2026-01-01T00:00:00Z"));

    await expect(duplicateDeck("deck1")).rejects.toThrow(/Trash/i);

    // No fresh deck or card copies were created from a trashed source.
    expect(create).not.toHaveBeenCalled();
    expect(cardsCreate).not.toHaveBeenCalled();
    expect(cardsGetFullList).not.toHaveBeenCalled();
  });

  it("duplicates a live source deck into a fresh live copy", async () => {
    getFirstListItem.mockResolvedValue(makeDeck("deck1", ""));
    create.mockResolvedValue(makeDeck("deck1-copy", ""));
    cardsGetFullList.mockResolvedValue([]);

    const copy = await duplicateDeck("deck1");

    expect(create).toHaveBeenCalledTimes(1);
    const createdData = create.mock.calls[0][0] as { name: string; deleted_at: string };
    expect(createdData.name).toBe("deck1 (copy)");
    expect(createdData.deleted_at).toBe("");
    expect(copy.id).toBe("deck1-copy");
  });
});
