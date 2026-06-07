import { beforeEach, describe, expect, it } from "vitest";

import { PoseDeckDB } from "../db";
import type { OutboxEntity } from "../db";
import { enqueue } from "../outbox";
import {
  clearLocalStore,
  hydrateFromServer,
  incomingWins,
  liveCards,
  liveCardImages,
  liveDeck,
  liveDecks,
  liveTrashedDecks,
  mergeRecord,
  reconcileEntity,
} from "../localStore";
import type { Card, CardImage, Deck } from "../types";

function freshDb(): PoseDeckDB {
  return new PoseDeckDB(`test-${crypto.randomUUID()}`);
}

function deck(over: Partial<Deck> = {}): Deck {
  return {
    id: "d1",
    owner: "u1",
    name: "Deck",
    shoot_date: "",
    client_updated_at: "2026-06-07T00:00:00.000Z",
    created: "2026-06-07T00:00:00.000Z",
    updated: "2026-06-07T00:00:00.000Z",
    deleted_at: "",
    ...over,
  };
}

function card(over: Partial<Card> = {}): Card {
  return {
    id: "c1",
    deck: "d1",
    position: 1000,
    title: "Card",
    time_slot: "",
    subjects: "",
    direction: "",
    notes: "",
    client_updated_at: "2026-06-07T00:00:00.000Z",
    created: "",
    updated: "",
    deleted_at: "",
    ...over,
  };
}

function image(over: Partial<CardImage> = {}): CardImage {
  return { id: "i1", card: "c1", position: 1, file: "a.jpg", created: "", ...over };
}

describe("incomingWins (LWW truth table)", () => {
  it("decks/cards: strictly-newer client_updated_at wins; ties skip", () => {
    const local = deck({ client_updated_at: "2026-06-07T00:00:00.000Z" });
    expect(incomingWins("decks", local, deck({ client_updated_at: "2026-06-07T00:00:01.000Z" }))).toBe(true);
    expect(incomingWins("decks", local, deck({ client_updated_at: "2026-06-06T00:00:00.000Z" }))).toBe(false);
    expect(incomingWins("decks", local, deck({ client_updated_at: "2026-06-07T00:00:00.000Z" }))).toBe(false); // tie
  });

  it("absent local always loses to incoming", () => {
    expect(incomingWins("decks", undefined, deck())).toBe(true);
  });

  it("empty incoming clock falls back to server `updated`", () => {
    const local = deck({ client_updated_at: "2026-06-07T00:00:05.000Z", updated: "2026-06-07T00:00:05.000Z" });
    // Incoming has empty client clock but a newer server `updated`.
    expect(
      incomingWins("decks", local, deck({ client_updated_at: "", updated: "2026-06-07T00:00:09.000Z" })),
    ).toBe(true);
    expect(
      incomingWins("decks", local, deck({ client_updated_at: "", updated: "2026-06-07T00:00:01.000Z" })),
    ).toBe(false);
  });

  it("card_completions order by changed_at", () => {
    const mk = (changed_at: string) =>
      ({ id: "x", card: "c", user: "u", state: "done", changed_at }) as never;
    expect(incomingWins("card_completions", mk("t1"), mk("t2"))).toBe(true);
    expect(incomingWins("card_completions", mk("t2"), mk("t1"))).toBe(false);
  });

  it("images/guests have no clock → idempotent upsert always 'wins'", () => {
    expect(incomingWins("card_images", image(), image({ position: 2 }))).toBe(true);
  });
});

describe("mergeRecord", () => {
  let db: PoseDeckDB;
  beforeEach(async () => {
    db = freshDb();
    await db.open();
  });

  it("applies a newer deck and skips an older one", async () => {
    await db.decks.put(deck({ name: "v1", client_updated_at: "2026-06-07T00:00:05.000Z" }));
    await mergeRecord(db, "decks", deck({ name: "v2-newer", client_updated_at: "2026-06-07T00:00:09.000Z" }));
    expect((await db.decks.get("d1"))?.name).toBe("v2-newer");
    await mergeRecord(db, "decks", deck({ name: "v0-older", client_updated_at: "2026-06-07T00:00:01.000Z" }));
    expect((await db.decks.get("d1"))?.name).toBe("v2-newer");
  });

  it("hard-deletes on a delete event regardless of clocks", async () => {
    await db.card_images.put(image());
    await mergeRecord(db, "card_images", image(), { deleted: true });
    expect(await db.card_images.get("i1")).toBeUndefined();
  });
});

describe("reconcileEntity prune", () => {
  let db: PoseDeckDB;
  beforeEach(async () => {
    db = freshDb();
    await db.open();
  });

  it("adds server rows and prunes local rows absent from the server set", async () => {
    await db.card_images.bulkPut([image({ id: "i1" }), image({ id: "i2" }), image({ id: "i3" })]);
    // Server now only knows i1 + a new i9.
    await reconcileEntity(db, "card_images", [image({ id: "i1" }), image({ id: "i9" })]);
    const ids = (await db.card_images.toArray()).map((r) => r.id).sort();
    expect(ids).toEqual(["i1", "i9"]); // i2, i3 pruned
  });

  it("exempts pending (keepIds) rows from pruning", async () => {
    await db.decks.bulkPut([deck({ id: "d1" }), deck({ id: "d-local" })]);
    await reconcileEntity(db, "decks", [deck({ id: "d1" })], new Set(["d-local"]));
    const ids = (await db.decks.toArray()).map((r) => r.id).sort();
    expect(ids).toEqual(["d-local", "d1"]); // optimistic local create survives
  });
});

describe("hydrateFromServer", () => {
  let db: PoseDeckDB;
  beforeEach(async () => {
    db = freshDb();
    await db.open();
  });

  it("merges all entities and preserves a pending optimistic create", async () => {
    // A local optimistic deck create not yet on the server.
    await db.decks.put(deck({ id: "d-pending", name: "pending" }));
    await enqueue(db, { type: "create", entity: "decks", recordId: "d-pending", payload: {} });

    const server: Record<OutboxEntity, unknown[]> = {
      decks: [deck({ id: "d1", name: "server" })],
      cards: [card({ id: "c1", deck: "d1" })],
      card_images: [image({ id: "i1", card: "c1" })],
      deck_guests: [],
      card_completions: [],
    };
    await hydrateFromServer(db, async (e) => server[e] as never);

    const deckIds = (await db.decks.toArray()).map((d) => d.id).sort();
    expect(deckIds).toEqual(["d-pending", "d1"]); // pending survived prune
    expect(await db.cards.count()).toBe(1);
    expect(await db.card_images.count()).toBe(1);
  });
});

describe("live read queries", () => {
  let db: PoseDeckDB;
  beforeEach(async () => {
    db = freshDb();
    await db.open();
  });

  it("liveDecks excludes soft-deleted; liveTrashedDecks includes only them", async () => {
    await db.decks.bulkPut([
      deck({ id: "live1", deleted_at: "" }),
      deck({ id: "trash1", deleted_at: "2026-06-07T01:00:00.000Z" }),
      deck({ id: "trash2", deleted_at: "2026-06-07T02:00:00.000Z" }),
    ]);
    expect((await liveDecks(db)).map((d) => d.id)).toEqual(["live1"]);
    // newest-deleted first
    expect((await liveTrashedDecks(db)).map((d) => d.id)).toEqual(["trash2", "trash1"]);
  });

  it("liveDeck returns undefined for a soft-deleted deck", async () => {
    await db.decks.put(deck({ id: "d1", deleted_at: "2026-06-07T01:00:00.000Z" }));
    expect(await liveDeck(db, "d1")).toBeUndefined();
  });

  it("liveCards filters soft-deleted and orders by position", async () => {
    await db.cards.bulkPut([
      card({ id: "c2", deck: "d1", position: 2000 }),
      card({ id: "c1", deck: "d1", position: 1000 }),
      card({ id: "cX", deck: "d1", position: 500, deleted_at: "2026-06-07T01:00:00.000Z" }),
      card({ id: "other", deck: "d2", position: 1000 }),
    ]);
    expect((await liveCards(db, "d1")).map((c) => c.id)).toEqual(["c1", "c2"]);
  });

  it("liveCardImages orders by position", async () => {
    await db.card_images.bulkPut([
      image({ id: "i2", card: "c1", position: 2 }),
      image({ id: "i1", card: "c1", position: 1 }),
    ]);
    expect((await liveCardImages(db, "c1")).map((i) => i.id)).toEqual(["i1", "i2"]);
  });
});

describe("clearLocalStore", () => {
  it("wipes all tables", async () => {
    const db = freshDb();
    await db.open();
    await db.decks.put(deck());
    await enqueue(db, { type: "create", entity: "decks", recordId: "d1", payload: {} });
    await clearLocalStore(db);
    expect(await db.decks.count()).toBe(0);
    expect(await db.outbox.count()).toBe(0);
  });
});
