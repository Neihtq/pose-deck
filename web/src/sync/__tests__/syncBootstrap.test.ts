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
