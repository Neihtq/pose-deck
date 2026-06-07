import { beforeEach, describe, expect, it } from "vitest";

import { PoseDeckDB } from "../db";
import type { OutboxEntity } from "../db";
import { enqueue } from "../outbox";
import {
  clearLocalStore,
  clearRecentlyCreated,
  clearRecentlyUploadedImages,
  hydrateFromServer,
  incomingWins,
  liveCards,
  liveCardImages,
  liveDeck,
  liveDecks,
  liveTrashedDecks,
  liveDeckGuests,
  markRecentlyCreated,
  markRecentlyUploadedImage,
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

  // Regression (E2E "Deck not found", root cause): the prune re-reads exemptions
  // via `lateKeep` RIGHT BEFORE the destructive bulkDelete, not from a snapshot
  // taken up front. We model a row that appears AND becomes exempt only after
  // the call begins (created mid-hydrate): the static `keepIds` does NOT cover
  // it, only the late re-read does. Without the late re-read this row is pruned.
  it("re-reads exemptions at prune time via lateKeep (covers mid-hydrate creates)", async () => {
    await db.decks.bulkPut([deck({ id: "d1" }), deck({ id: "d-late" })]);
    let lateKeepCalls = 0;
    await reconcileEntity(
      db,
      "decks",
      [deck({ id: "d1" })], // server snapshot lacks d-late
      new Set(), // early exemptions are EMPTY (d-late not yet known)
      () => {
        lateKeepCalls += 1;
        // Evaluated just before the prune — by now d-late is exempt.
        return new Set(["d-late"]);
      },
    );
    const ids = (await db.decks.toArray()).map((r) => r.id).sort();
    expect(lateKeepCalls).toBe(1); // late exemptions were consulted
    expect(ids).toEqual(["d-late", "d1"]); // late-exempted row survived the prune
  });

  it("lateKeep unions with the static keepIds (neither alone is enough)", async () => {
    await db.decks.bulkPut([
      deck({ id: "d1" }),
      deck({ id: "d-early" }),
      deck({ id: "d-late" }),
    ]);
    await reconcileEntity(
      db,
      "decks",
      [deck({ id: "d1" })],
      new Set(["d-early"]), // exempt via the early snapshot
      () => new Set(["d-late"]), // exempt via the late re-read
    );
    const ids = (await db.decks.toArray()).map((r) => r.id).sort();
    expect(ids).toEqual(["d-early", "d-late", "d1"]); // both kept
  });
});

describe("hydrateFromServer", () => {
  let db: PoseDeckDB;
  beforeEach(async () => {
    db = freshDb();
    await db.open();
    clearRecentlyUploadedImages();
    clearRecentlyCreated();
  });

  // Regression (finding C5): a directly-uploaded image (PB-direct, never in the
  // outbox) must not be pruned by a hydrate/resync whose server snapshot was
  // captured before the upload's create committed. Since images never enter the
  // outbox, `keepIds` from pendingRecordIds is empty — the recently-uploaded
  // mark is the only thing that can protect the optimistic row.
  it("does not prune a just-uploaded image absent from a racing server snapshot", async () => {
    // Optimistic row written by uploadCardImage's db.card_images.put(...).
    await db.card_images.put(image({ id: "i-fresh", card: "c1" }));
    markRecentlyUploadedImage("i-fresh");

    const server: Record<OutboxEntity, unknown[]> = {
      decks: [],
      cards: [],
      // Stale snapshot: the fresh upload is NOT in the server list yet.
      card_images: [image({ id: "i-old", card: "c1" })],
      deck_guests: [],
      card_completions: [],
    };
    await hydrateFromServer(db, async (e) => server[e] as never);

    const ids = (await db.card_images.toArray()).map((r) => r.id).sort();
    expect(ids).toEqual(["i-fresh", "i-old"]); // fresh upload survived the prune
  });

  it("prunes a stale (un-marked) image absent from the server snapshot", async () => {
    // Without a recent-upload mark, an absent local image is a genuine
    // hard-delete / orphan and must still be pruned (no over-retention).
    await db.card_images.put(image({ id: "i-stale", card: "c1" }));

    const server: Record<OutboxEntity, unknown[]> = {
      decks: [],
      cards: [],
      card_images: [image({ id: "i-old", card: "c1" })],
      deck_guests: [],
      card_completions: [],
    };
    await hydrateFromServer(db, async (e) => server[e] as never);

    const ids = (await db.card_images.toArray()).map((r) => r.id).sort();
    expect(ids).toEqual(["i-old"]); // unmarked stale row pruned
  });

  // Regression (E2E "Deck not found" flake): a freshly-created deck/card whose
  // create has been CONFIRMED and dequeued from the outbox must not be pruned by
  // an in-flight hydrate whose `getFullList` snapshot was captured BEFORE the
  // server committed the insert. `pendingRecordIds` only covers the still-queued
  // window; the recently-created mark covers the post-dequeue gap.
  it("does not prune a just-created deck absent from a racing server snapshot", async () => {
    // Optimistic deck create with NO pending outbox entry (already confirmed +
    // dequeued) — only the recently-created mark can protect it.
    await db.decks.put(deck({ id: "d-fresh", name: "fresh" }));
    markRecentlyCreated("decks", "d-fresh");

    const server: Record<OutboxEntity, unknown[]> = {
      decks: [deck({ id: "d-old", name: "old" })], // stale: d-fresh not yet present
      cards: [],
      card_images: [],
      deck_guests: [],
      card_completions: [],
    };
    await hydrateFromServer(db, async (e) => server[e] as never);

    const ids = (await db.decks.toArray()).map((d) => d.id).sort();
    expect(ids).toEqual(["d-fresh", "d-old"]); // fresh create survived the prune
  });

  // FIX #8: an optimistic deck_guests grant whose server commit post-dates a
  // racing hydrate snapshot must survive the prune — exactly like decks/cards.
  it("does not prune a just-created deck_guest absent from a racing server snapshot", async () => {
    await db.deck_guests.put({
      id: "grant-fresh",
      deck: "d1",
      user: "u2",
      granted_at: "2026-06-07T00:00:00.000Z",
    });
    markRecentlyCreated("deck_guests", "grant-fresh");

    const server: Record<OutboxEntity, unknown[]> = {
      decks: [],
      cards: [],
      card_images: [],
      deck_guests: [
        {
          id: "grant-old",
          deck: "d1",
          user: "u3",
          granted_at: "2026-06-06T00:00:00.000Z",
        },
      ], // stale: grant-fresh not yet present
      card_completions: [],
    };
    await hydrateFromServer(db, async (e) => server[e] as never);

    const ids = (await db.deck_guests.toArray()).map((g) => g.id).sort();
    expect(ids).toEqual(["grant-fresh", "grant-old"]); // optimistic grant survived
  });

  it("does not prune a just-created card absent from a racing server snapshot", async () => {
    await db.cards.put(card({ id: "c-fresh", deck: "d1" }));
    markRecentlyCreated("cards", "c-fresh");

    const server: Record<OutboxEntity, unknown[]> = {
      decks: [],
      cards: [card({ id: "c-old", deck: "d1" })], // stale: c-fresh not yet present
      card_images: [],
      deck_guests: [],
      card_completions: [],
    };
    await hydrateFromServer(db, async (e) => server[e] as never);

    const ids = (await db.cards.toArray()).map((c) => c.id).sort();
    expect(ids).toEqual(["c-fresh", "c-old"]);
  });

  it("still prunes an un-marked deck absent from the server snapshot", async () => {
    // No recent-create mark: an absent local deck is a genuine remote delete and
    // must still be pruned (no over-retention regression).
    await db.decks.put(deck({ id: "d-stale", name: "stale" }));

    const server: Record<OutboxEntity, unknown[]> = {
      decks: [deck({ id: "d-old", name: "old" })],
      cards: [],
      card_images: [],
      deck_guests: [],
      card_completions: [],
    };
    await hydrateFromServer(db, async (e) => server[e] as never);

    const ids = (await db.decks.toArray()).map((d) => d.id).sort();
    expect(ids).toEqual(["d-old"]); // unmarked stale row pruned
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
    expect((await liveTrashedDecks(db, "u1")).map((d) => d.id)).toEqual([
      "trash2",
      "trash1",
    ]);
  });

  // FIX #3: Trash is owner-scoped — a guest's mirror may hold an owner's
  // trashed SHARED deck (decks listRule still returns it), but it must never
  // appear in the guest's Trash.
  it("liveTrashedDecks excludes decks owned by another user", async () => {
    await db.decks.bulkPut([
      deck({ id: "mine", deleted_at: "2026-06-07T01:00:00.000Z" }), // owner u1
      deck({
        id: "theirs",
        owner: "u2",
        deleted_at: "2026-06-07T02:00:00.000Z",
      }),
    ]);
    expect((await liveTrashedDecks(db, "u1")).map((d) => d.id)).toEqual([
      "mine",
    ]);
  });

  it("liveDeckGuests returns a deck's guests ordered by granted_at", async () => {
    await db.deck_guests.bulkPut([
      { id: "g2", deck: "d1", user: "uB", granted_at: "2026-06-07T02:00:00.000Z" },
      { id: "g1", deck: "d1", user: "uA", granted_at: "2026-06-07T01:00:00.000Z" },
      { id: "gX", deck: "other", user: "uC", granted_at: "2026-06-07T03:00:00.000Z" },
    ]);
    expect((await liveDeckGuests(db, "d1")).map((g) => g.id)).toEqual([
      "g1",
      "g2",
    ]);
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
