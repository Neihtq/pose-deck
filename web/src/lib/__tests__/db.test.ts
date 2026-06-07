import Dexie from "dexie";
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
          "_meta",
          "card_completions",
          "card_images",
          "cards",
          "deck_guests",
          "decks",
          "image_blobs",
          "outbox",
          "pinned_decks",
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

  it("exposes deck_guests and _meta tables (v2) and round-trips them", async () => {
    const db = new PoseDeckDB(`test-${crypto.randomUUID()}`);
    await db.open();
    try {
      await db.deck_guests.put({
        id: "g1",
        deck: "d1",
        user: "u2",
        granted_at: "2026-06-07T00:00:00.000Z",
      });
      expect((await db.deck_guests.get("g1"))?.user).toBe("u2");

      await db._meta.put({ key: "cursor:decks", value: "2026-06-07" });
      expect((await db._meta.get("cursor:decks"))?.value).toBe("2026-06-07");
    } finally {
      db.close();
    }
  });

  it("exposes image_blobs + pinned_decks tables (v3) and round-trips them", async () => {
    const db = new PoseDeckDB(`test-${crypto.randomUUID()}`);
    await db.open();
    try {
      const bytes = new Blob(["fake"], { type: "image/jpeg" });
      await db.image_blobs.put({
        key: "card_images/img1/photo.jpg@thumb=200x200",
        card: "card1",
        recordId: "img1",
        blob: bytes,
        cachedAt: 123,
      });
      const loaded = await db.image_blobs.get(
        "card_images/img1/photo.jpg@thumb=200x200",
      );
      expect(loaded?.recordId).toBe("img1");
      // The `card` index supports bulk eviction on unpin.
      expect(await db.image_blobs.where("card").equals("card1").count()).toBe(1);

      await db.pinned_decks.put({ deckId: "deck1", pinnedAt: 456 });
      expect((await db.pinned_decks.get("deck1"))?.pinnedAt).toBe(456);
    } finally {
      db.close();
    }
  });

  it("preserves v1 outbox rows across the v2 upgrade", async () => {
    const name = `test-${crypto.randomUUID()}`;
    // Open at v1 by constructing a throwaway Dexie with only the v1 schema.
    const v1 = new Dexie(name);
    v1.version(1).stores({
      decks: "id, owner, shoot_date, deleted_at, client_updated_at",
      cards: "id, deck, position, deleted_at, client_updated_at",
      card_images: "id, card, position",
      card_completions: "id, card, user, state, [card+user]",
      outbox: "++id, entity, recordId, idempotency_key",
    });
    await v1.open();
    await v1.table("outbox").add({
      type: "create",
      entity: "decks",
      recordId: "legacy-1",
      payload: "{}",
      idempotency_key: crypto.randomUUID(),
      local_timestamp: new Date().toISOString(),
      retry_count: 0,
    });
    v1.close();

    // Reopen with the full (v2) schema and confirm the legacy row survived.
    const db = new PoseDeckDB(name);
    await db.open();
    try {
      const rows = await db.outbox.orderBy("id").toArray();
      expect(rows).toHaveLength(1);
      expect(rows[0].recordId).toBe("legacy-1");
      // v1 rows have no `status`; the queue treats absent status as pending.
      expect(rows[0].status).toBeUndefined();
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
