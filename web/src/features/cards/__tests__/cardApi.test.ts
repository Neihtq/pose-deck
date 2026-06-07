import { beforeEach, describe, expect, it, vi } from "vitest";

import { db } from "@/lib/db";
import { decodeOutboxPayload } from "@/lib/outbox";
import type { Card } from "@/lib/types";

// The sync runtime is wired separately (sync/index). Mock its wake() seam so
// cardApi's local-first writes never try to construct a real engine here.
vi.mock("@/sync", () => ({ wakeSync: vi.fn() }));

import {
  POSITION_GAP,
  computeReorderedPositions,
  createCard,
  nextPosition,
  reorderCards,
  updateCard,
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

beforeEach(async () => {
  await Promise.all([db.cards.clear(), db.outbox.clear()]);
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

describe("createCard (local-first)", () => {
  it("computes position from the deck's live Dexie cards and writes + enqueues", async () => {
    await db.cards.bulkPut([makeCard("a", 1000), makeCard("b", 2000)]);

    const card = await createCard("deck1", { title: "New shot" });

    // Optimistic Dexie row.
    expect(card.deck).toBe("deck1");
    expect(card.position).toBe(3000);
    expect(card.title).toBe("New shot");
    expect(card.time_slot).toBe("");
    expect(card.deleted_at).toBe("");
    expect(card.client_updated_at).not.toBe("");
    const stored = await db.cards.get(card.id);
    expect(stored?.title).toBe("New shot");

    // Exactly one outbox create entry carrying the same id + fields.
    const entries = await db.outbox.where("recordId").equals(card.id).toArray();
    expect(entries).toHaveLength(1);
    expect(entries[0].type).toBe("create");
    expect(entries[0].entity).toBe("cards");
    const payload = decodeOutboxPayload(entries[0]);
    expect(payload.position).toBe(3000);
    expect(payload.title).toBe("New shot");
  });

  it("starts at POSITION_GAP for an empty deck", async () => {
    const card = await createCard("deck1", { title: "First" });
    expect(card.position).toBe(POSITION_GAP);
  });

  it("ignores soft-deleted cards when computing the next position", async () => {
    await db.cards.bulkPut([
      makeCard("a", 1000),
      { ...makeCard("b", 9000), deleted_at: "2026-01-01T00:00:00Z" },
    ]);
    const card = await createCard("deck1", { title: "Next" });
    // Max live position is 1000, so the next is 2000 (the trashed 9000 ignored).
    expect(card.position).toBe(2000);
  });
});

describe("updateCard (local-first)", () => {
  it("writes only the provided fields to Dexie + enqueues a coalesced update", async () => {
    await db.cards.put(makeCard("c1", 1000));

    await updateCard("c1", { title: "Renamed" });

    const stored = await db.cards.get("c1");
    expect(stored?.title).toBe("Renamed");
    expect(stored?.client_updated_at).not.toBe("");

    const entries = await db.outbox.where("recordId").equals("c1").toArray();
    expect(entries).toHaveLength(1);
    expect(entries[0].type).toBe("update");
    const payload = decodeOutboxPayload<Record<string, unknown>>(entries[0]);
    expect(payload.title).toBe("Renamed");
    // Untouched fields are not in the patch.
    expect("notes" in payload).toBe(false);
  });
});

describe("reorderCards (local-first)", () => {
  it("restripes positions and enqueues one update per moved card", async () => {
    await db.cards.bulkPut([
      makeCard("a", 1000),
      makeCard("b", 2000),
      makeCard("c", 3000),
    ]);

    await reorderCards("deck1", ["c", "a", "b"]);

    // No currentPositions → every card is treated as moved (3 entries).
    const entries = await db.outbox.where("entity").equals("cards").toArray();
    const byId = new Map(entries.map((e) => [e.recordId, decodeOutboxPayload<{ position: number }>(e)]));
    expect(byId.get("c")?.position).toBe(1000);
    expect(byId.get("a")?.position).toBe(2000);
    expect(byId.get("b")?.position).toBe(3000);
    expect(entries).toHaveLength(3);
    // Dexie reflects the new positions.
    expect((await db.cards.get("c"))?.position).toBe(1000);
  });

  it("skips cards whose position did not change", async () => {
    await db.cards.bulkPut([
      makeCard("a", 1000),
      makeCard("b", 2000),
      makeCard("c", 3000),
    ]);
    const currentPositions = new Map([
      ["a", 1000],
      ["b", 2000],
      ["c", 3000],
    ]);

    // Move only "c" ahead of "b": b -> 3000, c -> 2000, "a" untouched at 1000.
    await reorderCards("deck1", ["a", "c", "b"], currentPositions);

    const entries = await db.outbox.where("entity").equals("cards").toArray();
    const writtenIds = entries.map((e) => e.recordId).sort();
    expect(writtenIds).toEqual(["b", "c"]);
    expect(writtenIds).not.toContain("a");
  });

  it("writes nothing when the order is unchanged", async () => {
    await db.cards.bulkPut([makeCard("a", 1000), makeCard("b", 2000)]);
    const currentPositions = new Map([
      ["a", 1000],
      ["b", 2000],
    ]);

    await reorderCards("deck1", ["a", "b"], currentPositions);

    const entries = await db.outbox.where("entity").equals("cards").toArray();
    expect(entries).toHaveLength(0);
  });

  it("accepts a plain object of current positions", async () => {
    await db.cards.bulkPut([
      makeCard("a", 1000),
      makeCard("b", 2000),
      makeCard("c", 3000),
    ]);

    await reorderCards("deck1", ["a", "c", "b"], {
      a: 1000,
      b: 2000,
      c: 3000,
    });

    const entries = await db.outbox.where("entity").equals("cards").toArray();
    const writtenIds = entries.map((e) => e.recordId).sort();
    expect(writtenIds).toEqual(["b", "c"]);
  });
});
