import { beforeEach, describe, expect, it, vi } from "vitest";

import { db } from "@/lib/db";
import { decodeOutboxPayload } from "@/lib/outbox";
import type { Card, Deck } from "@/lib/types";

// Mock the sync wake() seam (the engine is wired separately).
vi.mock("@/sync", () => ({ wakeSync: vi.fn() }));

// Provide an authenticated user so `currentUserId()` can stamp `owner`.
vi.mock("@/lib/pocketbase", () => ({
  pb: { authStore: { record: { id: "user1" } } },
}));

import {
  createDeck,
  duplicateDeck,
  renameDeck,
  restoreDeck,
  softDeleteDeck,
} from "@/features/decks/deckApi";

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
  };
}

function makeCard(id: string, deck: string, position: number): Card {
  return {
    id,
    deck,
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
  await Promise.all([db.decks.clear(), db.cards.clear(), db.outbox.clear()]);
});

describe("createDeck (local-first)", () => {
  it("stamps owner from the auth store, writes Dexie + enqueues a create", async () => {
    const deck = await createDeck({ name: "Smith Wedding" });

    expect(deck.owner).toBe("user1");
    expect(deck.name).toBe("Smith Wedding");
    expect(deck.deleted_at).toBe("");
    expect(deck.client_updated_at).not.toBe("");
    // Client-supplied PB-shaped id (15 chars).
    expect(deck.id).toHaveLength(15);

    const stored = await db.decks.get(deck.id);
    expect(stored?.name).toBe("Smith Wedding");

    const entries = await db.outbox.where("recordId").equals(deck.id).toArray();
    expect(entries).toHaveLength(1);
    expect(entries[0].type).toBe("create");
    expect(entries[0].entity).toBe("decks");
    const payload = decodeOutboxPayload<{ owner: string; name: string }>(
      entries[0],
    );
    // owner MUST be carried in the create payload (load-bearing M1 fix).
    expect(payload.owner).toBe("user1");
    expect(payload.name).toBe("Smith Wedding");
  });
});

describe("renameDeck / softDeleteDeck / restoreDeck (local-first)", () => {
  it("rename writes the new name + enqueues an update", async () => {
    await db.decks.put(makeDeck("d1", ""));
    await renameDeck("d1", "Renamed");
    expect((await db.decks.get("d1"))?.name).toBe("Renamed");
    const entries = await db.outbox.where("recordId").equals("d1").toArray();
    expect(entries[0].type).toBe("update");
    expect(decodeOutboxPayload<{ name: string }>(entries[0]).name).toBe(
      "Renamed",
    );
  });

  it("softDelete sets deleted_at; restore clears it (coalesced into one update)", async () => {
    await db.decks.put(makeDeck("d1", ""));
    await softDeleteDeck("d1");
    expect((await db.decks.get("d1"))?.deleted_at).not.toBe("");
    await restoreDeck("d1");
    expect((await db.decks.get("d1"))?.deleted_at).toBe("");
    // The two updates coalesce into a single pending update entry.
    const entries = await db.outbox.where("recordId").equals("d1").toArray();
    expect(entries).toHaveLength(1);
    expect(decodeOutboxPayload<{ deleted_at: string }>(entries[0]).deleted_at).toBe(
      "",
    );
  });
});

describe("duplicateDeck (soft-deleted source guard, finding C2)", () => {
  it("refuses to duplicate a soft-deleted source deck and creates no copy", async () => {
    await db.decks.put(makeDeck("deck1", "2026-01-01T00:00:00Z"));

    await expect(duplicateDeck("deck1")).rejects.toThrow(/Trash/i);

    // Only the trashed source exists; no fresh deck/card copies were written.
    expect(await db.decks.count()).toBe(1);
    expect(await db.cards.count()).toBe(0);
    expect(await db.outbox.count()).toBe(0);
  });

  it("refuses to duplicate a missing deck", async () => {
    await expect(duplicateDeck("nope")).rejects.toThrow(/Trash/i);
  });

  it("duplicates a live source deck + its live cards into a fresh local copy", async () => {
    await db.decks.put(makeDeck("deck1", ""));
    await db.cards.bulkPut([
      makeCard("c1", "deck1", 1000),
      makeCard("c2", "deck1", 2000),
      { ...makeCard("c3", "deck1", 3000), deleted_at: "2026-01-01T00:00:00Z" },
    ]);

    const copy = await duplicateDeck("deck1");

    expect(copy.name).toBe("deck1 (copy)");
    expect(copy.deleted_at).toBe("");
    expect(copy.id).not.toBe("deck1");

    // The copy + its two LIVE cards (the trashed one is not copied).
    const copiedCards = await db.cards.where("deck").equals(copy.id).toArray();
    expect(copiedCards).toHaveLength(2);
    expect(copiedCards.map((c) => c.position).sort((a, b) => a - b)).toEqual([
      1000, 2000,
    ]);

    // Outbox: one deck create + two card creates.
    const entries = await db.outbox.toArray();
    const deckCreates = entries.filter((e) => e.entity === "decks");
    const cardCreates = entries.filter((e) => e.entity === "cards");
    expect(deckCreates).toHaveLength(1);
    expect(cardCreates).toHaveLength(2);
  });
});
