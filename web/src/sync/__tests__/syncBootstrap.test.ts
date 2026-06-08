/**
 * Unit tests for the sync bootstrap (`sync/index.ts`): the engine hook wiring
 * (reconcile → mergeRecord, onConfirmed → recentlyConfirmed.mark, rollback →
 * remove a dropped create) and the PocketBase realtime-provider adapter.
 */
import { beforeEach, describe, expect, it, vi } from "vitest";
import { ClientResponseError } from "pocketbase";

import { PoseDeckDB } from "@/lib/db";
import { enqueue } from "@/lib/outbox";
import type { MutationTransport } from "@/lib/serverEntities";

// The bootstrap imports the toast helper; stub it so a dropped-entry error
// doesn't try to render a real toaster.
vi.mock("@/components/ui/use-toast", () => ({ toast: vi.fn() }));

// Stub the PocketBase module: `pb.autoCancellation` (called by startSync) and a
// `collections.decks().subscribe` spy so we can assert the realtime adapter
// forwards the SDK's {action, record} payload unchanged.
const subscribe = vi.fn();
const unsub = vi.fn(async () => {});
vi.mock("@/lib/pocketbase", () => ({
  pb: { autoCancellation: vi.fn() },
  collections: {
    decks: () => ({ subscribe }),
    cards: () => ({ subscribe }),
    card_images: () => ({ subscribe }),
    deck_guests: () => ({ subscribe }),
    card_completions: () => ({ subscribe }),
  },
}));

import { createSyncRuntime, pocketBaseRealtimeProvider } from "@/sync";

function freshDb(): PoseDeckDB {
  return new PoseDeckDB(`test-${crypto.randomUUID()}`);
}

describe("createSyncRuntime hook wiring", () => {
  let db: PoseDeckDB;
  beforeEach(async () => {
    db = freshDb();
    await db.open();
  });

  it("reconciles a 2xx create into Dexie and marks it recently-confirmed", async () => {
    const server = {
      id: "deck1",
      owner: "u1",
      name: "Server Name",
      shoot_date: "",
      deleted_at: "",
      client_updated_at: "2026-06-07T00:00:00.000Z",
      created: "2026-06-07T00:00:00.000Z",
      updated: "2026-06-07T00:00:00.000Z",
    };
    const transport: MutationTransport = {
      create: vi.fn(async () => server),
      update: vi.fn(),
      delete: vi.fn(),
    };
    const { engine, recentlyConfirmed } = createSyncRuntime(db, { transport });

    // The optimistic row carries an older clock than the server-canonical
    // record, so the reconcile merge (LWW) applies the server values.
    await db.decks.put({
      ...server,
      name: "Optimistic",
      client_updated_at: "2026-06-06T00:00:00.000Z",
    });
    await enqueue(db, {
      type: "create",
      entity: "decks",
      recordId: "deck1",
      payload: { name: "Optimistic" },
    });
    await engine.drain();

    // Server-canonical record merged into Dexie (newer/equal clock applied).
    expect((await db.decks.get("deck1"))?.name).toBe("Server Name");
    expect(await db.outbox.count()).toBe(0);
    // (entity,id) marked so realtime suppresses the echo of our own create.
    expect(recentlyConfirmed.shouldSuppress("decks", "deck1")).toBe(true);
  });

  // Regression (finding C2): in the REAL create flow the optimistic row seeds
  // created = updated = client_updated_at = stamp and sends that SAME stamp to
  // the server. The 2xx echo therefore carries an IDENTICAL client_updated_at —
  // a tie under LWW that the merge would skip — so the server-canonical
  // created/updated (which differ from the optimistic placeholders) must still
  // be written. Before the fix, reconcileEntry went through plain LWW and the
  // tie was skipped, leaving the optimistic created/updated in Dexie.
  it("writes server-canonical created/updated on 2xx even when client_updated_at ties", async () => {
    const stamp = "2026-06-07T12:00:00.000Z";
    const server = {
      id: "deck2",
      owner: "u1",
      name: "Server Name",
      shoot_date: "",
      deleted_at: "",
      // Server echoes back the exact client clock the client sent.
      client_updated_at: stamp,
      // ...but its OWN canonical created/updated differ from the optimistic
      // placeholders the client seeded with `stamp`.
      created: "2026-06-07T11:59:59.500Z",
      updated: "2026-06-07T11:59:59.700Z",
    };
    const transport: MutationTransport = {
      create: vi.fn(async () => server),
      update: vi.fn(),
      delete: vi.fn(),
    };
    const { engine } = createSyncRuntime(db, { transport });

    // optimisticDeck seeds created = updated = client_updated_at = stamp.
    await db.decks.put({
      id: "deck2",
      owner: "u1",
      name: "Server Name",
      shoot_date: "",
      deleted_at: "",
      client_updated_at: stamp,
      created: stamp,
      updated: stamp,
    });
    await enqueue(db, {
      type: "create",
      entity: "decks",
      recordId: "deck2",
      payload: { name: "Server Name" },
    });
    await engine.drain();

    const reconciled = await db.decks.get("deck2");
    expect(reconciled?.created).toBe(server.created);
    expect(reconciled?.updated).toBe(server.updated);
    expect(await db.outbox.count()).toBe(0);
  });

  // Regression (CORR-1): a user edits a card AGAIN while that card's previous
  // update is mid-send. The in-flight update's server echo carries the OLD
  // client_updated_at; if reconcile force-writes the whole stale record it
  // reverts the newer local edit (and every other field) to the old snapshot.
  // The fix: when a pending outbox entry for the same record carries a strictly
  // newer clock, reconcile writes ONLY server-canonical metadata
  // (id/created/updated) and leaves the newer local field values intact.
  it("does not clobber a newer local edit made during an in-flight update (CORR-1)", async () => {
    const T1 = "2026-06-08T10:00:00.000Z"; // first edit (the in-flight send)
    const T2 = "2026-06-08T10:00:05.000Z"; // second edit (made mid-send)

    // The server echo of the FIRST update: it reflects the T1 PATCH (old title)
    // and echoes back the T1 client clock, with its own canonical created/updated.
    const serverEchoT1 = {
      id: "cardA",
      deck: "deck1",
      position: 1000,
      title: "Title-T1",
      time_slot: "",
      subjects: "",
      direction: "",
      notes: "",
      deleted_at: "",
      client_updated_at: T1,
      created: "2026-06-08T09:00:00.000Z",
      updated: "2026-06-08T10:00:01.000Z",
    };

    // The transport: the FIRST in-flight update returns the T1 echo. While that
    // send is "in flight", interleave the user's SECOND edit — write the newer
    // row to Dexie and enqueue a separate pending update carrying the T2 clock.
    // The SECOND send (the T2 entry) is held off with a transient network error
    // so the T2 entry stays queued: this exposes CORR-1's genuine data-loss tail
    // (if reconcile reverted to T1 it would persist while T2 is undelivered),
    // and lets us assert on the post-reconcile row deterministically.
    let call = 0;
    const update = vi.fn(async () => {
      call += 1;
      if (call === 1) {
        await db.cards.put({
          ...serverEchoT1,
          title: "Title-T2",
          client_updated_at: T2,
          created: serverEchoT1.created,
          updated: serverEchoT1.updated,
        });
        await enqueue(db, {
          type: "update",
          entity: "cards",
          recordId: "cardA",
          payload: { title: "Title-T2", client_updated_at: T2 },
        });
        return serverEchoT1;
      }
      // T2 send: transient failure → entry stays queued, never reconciled.
      throw new ClientResponseError({ status: 0 });
    });
    const transport: MutationTransport = {
      create: vi.fn(),
      update,
      delete: vi.fn(),
    };
    const { engine } = createSyncRuntime(db, { transport });

    // Seed the optimistic row + queue the FIRST (T1) update.
    await db.cards.put({ ...serverEchoT1, title: "Title-T1" });
    await enqueue(db, {
      type: "update",
      entity: "cards",
      recordId: "cardA",
      payload: { title: "Title-T1", client_updated_at: T1 },
    });

    await engine.drain();

    const row = await db.cards.get("cardA");
    // The newer (T2) local edit must be preserved, NOT reverted to T1 by the
    // T1 echo's reconcile (CORR-1). The T2 send is still failing/queued, so a
    // bug here would be PERSISTENT data loss, not a transient thrash.
    expect(row?.title).toBe("Title-T2");
    expect(row?.client_updated_at).toBe(T2);
    // Server-canonical created from the echo is still applied (metadata-only).
    expect(row?.created).toBe(serverEchoT1.created);
    // The T2 update remains queued (its send is transiently failing).
    expect(await db.outbox.count()).toBe(1);
    // The guard had a newer pending T2 entry to detect on the first reconcile.
    expect(update).toHaveBeenCalledTimes(2);
  });

  it("rolls back (removes) a dropped optimistic create on a 4xx", async () => {
    const err = new ClientResponseError({ status: 403, data: {} });
    const transport: MutationTransport = {
      create: vi.fn(async () => {
        throw err;
      }),
      update: vi.fn(),
      delete: vi.fn(),
    };
    const { engine } = createSyncRuntime(db, { transport });

    await db.cards.put({
      id: "card1",
      deck: "deck1",
      position: 1000,
      title: "Doomed",
      time_slot: "",
      subjects: "",
      direction: "",
      notes: "",
      deleted_at: "",
      client_updated_at: "2026-06-07T00:00:00.000Z",
      created: "",
      updated: "",
    });
    await enqueue(db, {
      type: "create",
      entity: "cards",
      recordId: "card1",
      payload: { title: "Doomed" },
    });
    await engine.drain();

    // 4xx drop → the optimistic row is removed and the entry is gone.
    expect(await db.cards.get("card1")).toBeUndefined();
    expect(await db.outbox.count()).toBe(0);
  });
});

describe("pocketBaseRealtimeProvider adapter", () => {
  beforeEach(() => {
    subscribe.mockReset();
    subscribe.mockResolvedValue(unsub);
  });

  it("subscribes to '*' and forwards {action, record} to the callback", async () => {
    const received: unknown[] = [];
    const handle = await pocketBaseRealtimeProvider.subscribe("decks", (e) =>
      received.push(e),
    );

    // Subscribed to the wildcard topic.
    expect(subscribe).toHaveBeenCalledWith("*", expect.any(Function));
    // The returned handle is the SDK's unsubscribe function.
    expect(handle).toBe(unsub);

    // Drive the captured SDK callback; the adapter forwards action + record.
    const sdkCb = subscribe.mock.calls[0][1] as (d: unknown) => void;
    sdkCb({ action: "create", record: { id: "d1", name: "remote" } });
    expect(received).toEqual([
      { action: "create", record: { id: "d1", name: "remote" } },
    ]);
  });
});
