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
});
