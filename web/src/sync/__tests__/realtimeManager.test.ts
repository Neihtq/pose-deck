import { beforeEach, describe, expect, it, vi } from "vitest";

import { PoseDeckDB } from "@/lib/db";
import type { OutboxEntity } from "@/lib/db";
import type { Deck } from "@/lib/types";
import {
  RealtimeManager,
  type RealtimeEvent,
  type RealtimeProvider,
} from "../realtimeManager";
import { RecentlyConfirmed } from "../recentlyConfirmed";

function freshDb(): PoseDeckDB {
  return new PoseDeckDB(`test-${crypto.randomUUID()}`);
}

function deck(over: Partial<Deck> = {}): Deck & Record<string, unknown> {
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

/** A controllable fake realtime provider that records emitters per entity. */
function fakeProvider() {
  const emitters = new Map<OutboxEntity, (e: RealtimeEvent) => void>();
  const unsub = vi.fn(async () => {});
  const provider: RealtimeProvider = {
    subscribe: vi.fn(async (entity, cb) => {
      emitters.set(entity, cb);
      return unsub;
    }),
  };
  return {
    provider,
    unsub,
    emit: (entity: OutboxEntity, event: RealtimeEvent) => emitters.get(entity)!(event),
    subscribedEntities: () => [...emitters.keys()],
  };
}

const emptyFetch = async () => [];

describe("RealtimeManager lifecycle", () => {
  let db: PoseDeckDB;
  beforeEach(async () => {
    db = freshDb();
    await db.open();
  });

  it("subscribes to exactly the five synced collections, then hydrates", async () => {
    const f = fakeProvider();
    const fetchAll = vi.fn(emptyFetch);
    const rm = new RealtimeManager({ db, provider: f.provider, fetchAll });
    await rm.start();

    expect(f.subscribedEntities().sort()).toEqual(
      ["card_completions", "card_images", "cards", "deck_guests", "decks"].sort(),
    );
    // hydrate ran for all five entities after subscriptions opened.
    expect(fetchAll).toHaveBeenCalledTimes(5);
    expect(rm.isStarted).toBe(true);
  });

  it("is idempotent: a second start does not re-subscribe", async () => {
    const f = fakeProvider();
    const rm = new RealtimeManager({ db, provider: f.provider, fetchAll: emptyFetch });
    await rm.start();
    await rm.start();
    expect(f.provider.subscribe).toHaveBeenCalledTimes(5);
  });

  it("stop() unsubscribes all", async () => {
    const f = fakeProvider();
    const rm = new RealtimeManager({ db, provider: f.provider, fetchAll: emptyFetch });
    await rm.start();
    await rm.stop();
    expect(f.unsub).toHaveBeenCalledTimes(5);
    expect(rm.isStarted).toBe(false);
  });

  it("resync re-hydrates while started", async () => {
    const f = fakeProvider();
    const fetchAll = vi.fn(emptyFetch);
    const rm = new RealtimeManager({ db, provider: f.provider, fetchAll });
    await rm.start();
    fetchAll.mockClear();
    await rm.resync();
    expect(fetchAll).toHaveBeenCalledTimes(5);
  });
});

describe("RealtimeManager event application", () => {
  let db: PoseDeckDB;
  beforeEach(async () => {
    db = freshDb();
    await db.open();
  });

  it("applies a create/update via LWW", async () => {
    const f = fakeProvider();
    const rm = new RealtimeManager({ db, provider: f.provider, fetchAll: emptyFetch });
    await rm.start();

    f.emit("decks", { action: "create", record: deck({ id: "d1", name: "remote" }) });
    await vi.waitFor(async () => {
      expect((await db.decks.get("d1"))?.name).toBe("remote");
    });

    // An older update must NOT clobber the newer local row.
    f.emit("decks", {
      action: "update",
      record: deck({ id: "d1", name: "stale", client_updated_at: "2026-06-06T00:00:00.000Z" }),
    });
    await new Promise((r) => setTimeout(r, 10));
    expect((await db.decks.get("d1"))?.name).toBe("remote");
  });

  it("hard-removes on a delete event", async () => {
    const f = fakeProvider();
    await db.decks.put(deck({ id: "d1" }));
    const rm = new RealtimeManager({ db, provider: f.provider, fetchAll: emptyFetch });
    await rm.start();

    f.emit("decks", { action: "delete", record: deck({ id: "d1" }) });
    await vi.waitFor(async () => {
      expect(await db.decks.get("d1")).toBeUndefined();
    });
  });

  it("suppresses the echo of a just-confirmed local mutation", async () => {
    const f = fakeProvider();
    const rc = new RecentlyConfirmed(5000, () => 0);
    const onApplied = vi.fn();
    const rm = new RealtimeManager({
      db,
      provider: f.provider,
      fetchAll: emptyFetch,
      recentlyConfirmed: rc,
      onApplied,
    });
    await rm.start();

    rc.mark("decks", "d1"); // we just confirmed our own create
    f.emit("decks", { action: "create", record: deck({ id: "d1", name: "echo" }) });
    await new Promise((r) => setTimeout(r, 10));

    expect(onApplied).not.toHaveBeenCalled();
    expect(await db.decks.get("d1")).toBeUndefined(); // echo suppressed
  });

  // ---- M5 sharing: deck_guests side-effects (FIX #1/#2/#7-web) -----------

  function guest(over: Partial<{ id: string; deck: string; user: string; granted_at: string }> = {}) {
    return {
      id: "grant1",
      deck: "d1",
      user: "me",
      granted_at: "2026-06-07T00:00:00.000Z",
      ...over,
    };
  }

  // FIX #1: a CREATE granting ME a deck I don't yet mirror → resync, so
  // hydration pulls the now-visible deck + cards + images into Dexie.
  it("triggers a resync when granted a deck that is absent locally", async () => {
    const f = fakeProvider();
    const fetchAll = vi.fn(emptyFetch);
    const rm = new RealtimeManager({
      db,
      provider: f.provider,
      fetchAll,
      currentUserId: () => "me",
    });
    await rm.start();
    fetchAll.mockClear();

    f.emit("deck_guests", { action: "create", record: guest({ deck: "absent-deck" }) });
    await vi.waitFor(() => {
      // resync re-hydrates all five entities.
      expect(fetchAll).toHaveBeenCalledTimes(5);
    });
  });

  // FIX #1 (gate): a CREATE for a deck I ALREADY mirror is an echo — no resync.
  it("does NOT resync when granted a deck already present locally", async () => {
    const f = fakeProvider();
    const fetchAll = vi.fn(emptyFetch);
    const rm = new RealtimeManager({
      db,
      provider: f.provider,
      fetchAll,
      currentUserId: () => "me",
    });
    await rm.start();
    // Seed AFTER start so the start-time hydrate (emptyFetch) doesn't prune it.
    await db.decks.put(deck({ id: "d1", owner: "owner-x" }));
    fetchAll.mockClear();

    f.emit("deck_guests", { action: "create", record: guest({ deck: "d1" }) });
    await new Promise((r) => setTimeout(r, 20));
    expect(fetchAll).not.toHaveBeenCalled();
  });

  // FIX #1 (gate): a CREATE granting SOMEONE ELSE (owner echo) → no resync.
  it("does NOT resync on a grant for another user", async () => {
    const f = fakeProvider();
    const fetchAll = vi.fn(emptyFetch);
    const rm = new RealtimeManager({
      db,
      provider: f.provider,
      fetchAll,
      currentUserId: () => "me",
    });
    await rm.start();
    fetchAll.mockClear();

    f.emit("deck_guests", { action: "create", record: guest({ deck: "absent", user: "someone-else" }) });
    await new Promise((r) => setTimeout(r, 20));
    expect(fetchAll).not.toHaveBeenCalled();
  });

  // FIX #2 + #7-web: a DELETE revoking ME from a FOREIGN-owned deck → evict the
  // deck + its cards + card_images + image_blobs + pin from Dexie.
  it("cascade-evicts a foreign-owned deck when my guest access is revoked", async () => {
    const f = fakeProvider();
    const rm = new RealtimeManager({
      db, provider: f.provider, fetchAll: emptyFetch, currentUserId: () => "me",
    });
    await rm.start();
    // Seed AFTER start so the start-time hydrate (emptyFetch) doesn't prune it.
    await db.decks.put(deck({ id: "d1", owner: "owner-x" }));
    await db.cards.put({
      id: "c1", deck: "d1", position: 1000, title: "x", time_slot: "", subjects: "",
      direction: "", notes: "", client_updated_at: "", created: "", updated: "", deleted_at: "",
    });
    await db.card_images.put({ id: "img1", card: "c1", position: 1000, file: "p.png", created: "" });
    await db.image_blobs.put({ key: "k1", card: "c1", recordId: "img1", blob: new Blob(["x"]), cachedAt: 0 });
    await db.pinned_decks.put({ deckId: "d1", pinnedAt: 0 });
    await db.deck_guests.put(guest({ id: "grant1", deck: "d1", user: "me" }));

    f.emit("deck_guests", { action: "delete", record: guest({ id: "grant1", deck: "d1", user: "me" }) });
    await vi.waitFor(async () => {
      expect(await db.decks.get("d1")).toBeUndefined();
    });
    expect(await db.cards.get("c1")).toBeUndefined();
    expect(await db.card_images.get("img1")).toBeUndefined();
    expect(await db.image_blobs.get("k1")).toBeUndefined();
    expect(await db.pinned_decks.get("d1")).toBeUndefined();
    expect(await db.deck_guests.get("grant1")).toBeUndefined();
  });

  // FIX #7-web: an OWNER revoking their OWN guest must KEEP their deck.
  it("keeps the deck when I OWN it and a guest grant is deleted", async () => {
    const f = fakeProvider();
    const rm = new RealtimeManager({
      db, provider: f.provider, fetchAll: emptyFetch, currentUserId: () => "me",
    });
    await rm.start();
    // Seed AFTER start so the start-time hydrate (emptyFetch) doesn't prune it.
    await db.decks.put(deck({ id: "d1", owner: "me" }));
    await db.deck_guests.put(guest({ id: "grant1", deck: "d1", user: "me" }));

    f.emit("deck_guests", { action: "delete", record: guest({ id: "grant1", deck: "d1", user: "me" }) });
    await vi.waitFor(async () => {
      expect(await db.deck_guests.get("grant1")).toBeUndefined(); // grant row removed
    });
    expect(await db.decks.get("d1")).toBeDefined(); // but the owner's deck stays
  });

  // FIX #7-web: a DELETE whose deck row is ABSENT locally → no-op (can't confirm
  // foreign ownership, so never evict).
  it("does nothing on a revoke when the deck row is absent locally", async () => {
    const f = fakeProvider();
    const rm = new RealtimeManager({
      db, provider: f.provider, fetchAll: emptyFetch, currentUserId: () => "me",
    });
    await rm.start();
    // Should not throw; nothing to evict.
    f.emit("deck_guests", { action: "delete", record: guest({ id: "grant1", deck: "absent", user: "me" }) });
    await new Promise((r) => setTimeout(r, 20));
    expect(await db.decks.get("absent")).toBeUndefined();
  });

  // Regression (C4): a CONCURRENT remote write that is strictly newer than the
  // mutation we confirmed must be applied via LWW, not swallowed as our echo,
  // even when it arrives within the suppression TTL before our own echo.
  it("does NOT suppress a strictly-newer concurrent remote write within the TTL", async () => {
    const f = fakeProvider();
    const rc = new RecentlyConfirmed(5000, () => 0);
    const onApplied = vi.fn();
    const rm = new RealtimeManager({
      db,
      provider: f.provider,
      fetchAll: emptyFetch,
      recentlyConfirmed: rc,
      onApplied,
    });
    await rm.start();

    // Our optimistic local row + the clock we confirmed to the server.
    const confirmedClock = "2026-06-07T00:00:00.000Z";
    await db.decks.put(deck({ id: "d1", name: "ours", client_updated_at: confirmedClock }));
    rc.mark("decks", "d1", confirmedClock);

    // A guest's genuinely-newer edit to the same deck arrives first.
    f.emit("decks", {
      action: "update",
      record: deck({ id: "d1", name: "guest", client_updated_at: "2026-06-07T00:00:05.000Z" }),
    });
    await vi.waitFor(async () => {
      expect((await db.decks.get("d1"))?.name).toBe("guest");
    });
    expect(onApplied).toHaveBeenCalledTimes(1);

    // Our own echo (same clock we sent) still lands afterwards and is
    // suppressed — it must not clobber the newer guest value.
    f.emit("decks", {
      action: "update",
      record: deck({ id: "d1", name: "ours", client_updated_at: confirmedClock }),
    });
    await new Promise((r) => setTimeout(r, 10));
    expect((await db.decks.get("d1"))?.name).toBe("guest");
    expect(onApplied).toHaveBeenCalledTimes(1); // echo did not apply
  });
});
