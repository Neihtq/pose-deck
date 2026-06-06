import { describe, expect, it } from "vitest";

import { PoseDeckDB } from "../db";
import type { Deck } from "../types";
import { isCardCompletionState, isSoftDeleted } from "../types";

describe("PoseDeckDB schema", () => {
  it("opens and exposes all expected tables", async () => {
    const db = new PoseDeckDB(`test-${crypto.randomUUID()}`);
    await db.open();
    try {
      const tableNames = db.tables.map((t) => t.name).sort();
      expect(tableNames).toEqual(
        [
          "card_completions",
          "card_images",
          "cards",
          "decks",
          "outbox",
        ].sort(),
      );
    } finally {
      db.close();
    }
  });

  it("round-trips a deck record through the decks table", async () => {
    const db = new PoseDeckDB(`test-${crypto.randomUUID()}`);
    await db.open();
    try {
      const deck: Deck = {
        id: "deck1",
        owner: "user1",
        name: "Beach shoot",
        shoot_date: "",
        client_updated_at: "2026-06-06T10:00:00.000Z",
        created: "2026-06-06T10:00:00.000Z",
        updated: "2026-06-06T10:00:00.000Z",
        deleted_at: "",
      };
      await db.decks.put(deck);
      const loaded = await db.decks.get("deck1");
      expect(loaded?.name).toBe("Beach shoot");
    } finally {
      db.close();
    }
  });

  it("queues and reads back an outbox entry in FIFO order", async () => {
    const db = new PoseDeckDB(`test-${crypto.randomUUID()}`);
    await db.open();
    try {
      await db.outbox.add({
        type: "create",
        entity: "decks",
        recordId: "tmp-1",
        payload: JSON.stringify({ name: "x" }),
        idempotency_key: crypto.randomUUID(),
        local_timestamp: new Date().toISOString(),
        retry_count: 0,
      });
      const entries = await db.outbox.orderBy("id").toArray();
      expect(entries).toHaveLength(1);
      expect(entries[0].entity).toBe("decks");
    } finally {
      db.close();
    }
  });
});

describe("type guards", () => {
  it("validates card_completions state values", () => {
    expect(isCardCompletionState("done")).toBe(true);
    expect(isCardCompletionState("skipped")).toBe(true);
    expect(isCardCompletionState("pending")).toBe(true);
    expect(isCardCompletionState("nope")).toBe(false);
    expect(isCardCompletionState(undefined)).toBe(false);
  });

  it("detects soft-deleted records", () => {
    expect(isSoftDeleted({ deleted_at: "" })).toBe(false);
    expect(isSoftDeleted({ deleted_at: "2026-06-06T00:00:00.000Z" })).toBe(true);
  });
});
