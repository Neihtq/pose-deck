/**
 * Sync bootstrap (M3, ARCHITECTURE.md §4).
 *
 * Wires the sync primitives that steps 1–4 built into a single runtime over the
 * shared Dexie `db` and the live PocketBase client:
 *
 *  - a {@link SyncEngine} that drains the outbox FIFO, reconciling server
 *    timestamps into Dexie on 2xx and marking each confirmed mutation in the
 *    {@link RecentlyConfirmed} set (so the realtime layer skips our own echo);
 *  - a {@link RealtimeManager} fed by a real PocketBase realtime provider and a
 *    real `fetchAll` (getFullList per synced entity, INCLUDING soft-deleted
 *    decks/cards so trash reconciles), which subscribes first then hydrates.
 *
 * The app calls {@link startSync} on sign-in and {@link stopSync} on sign-out.
 * Both are idempotent and safe to call when already (not) running.
 */
import { db } from "@/lib/db";
import type { OutboxEntity, OutboxEntry, PoseDeckDB } from "@/lib/db";
import { decodeOutboxPayload } from "@/lib/outbox";
import {
  type EntityFetcher,
  clearLocalStore,
  hydrateFromServer,
  mergeRecord,
} from "@/lib/localStore";
import { clearFileToken, collections, pb } from "@/lib/pocketbase";
import { SyncEngine } from "@/lib/syncEngine";
import { type MutationTransport, lwwKey } from "@/lib/serverEntities";
import { toast } from "@/components/ui/use-toast";

/** Any stored collection row (all carry a string `id`). */
type AnyServerRecord = { id: string } & Record<string, unknown>;

import {
  RealtimeManager,
  type RealtimeEvent,
  type RealtimeProvider,
  type Unsubscribe,
} from "./realtimeManager";
import { RecentlyConfirmed } from "./recentlyConfirmed";

/**
 * The PocketBase realtime provider, adapting `pb.collection(name).subscribe`
 * to the {@link RealtimeProvider} interface. The SDK callback delivers
 * `{action, record}`; we forward it unchanged. `subscribe` resolves to an
 * `UnsubscribeFunc` (`() => Promise<void>`), which already matches
 * {@link Unsubscribe}.
 */
export const pocketBaseRealtimeProvider: RealtimeProvider = {
  subscribe(
    entity: OutboxEntity,
    cb: (event: RealtimeEvent) => void,
  ): Promise<Unsubscribe> {
    return collections[entity]().subscribe("*", (data) => {
      const evt = data as unknown as {
        action: string;
        record: RealtimeEvent["record"];
      };
      cb({ action: evt.action, record: evt.record });
    }) as Promise<Unsubscribe>;
  },
};

/**
 * Fetch ALL viewable records for an entity across pages, INCLUDING soft-deleted
 * ones. The `listRule`/`viewRule` already scope to owner+guest decks; we must
 * NOT add a `deleted_at = ""` filter here, or trashed decks/cards would be
 * pruned out of Dexie by the reconciling resync and vanish from the trash view.
 * Images / guests / completions have no soft-delete, so they need no filter.
 */
export const pocketBaseFetchAll: EntityFetcher = async (entity) => {
  const records = await collections[entity]().getFullList();
  return records as unknown as Parameters<typeof mergeRecord>[2][];
};

/** Reconcile server-canonical fields into the local row after a 2xx send. */
async function reconcileEntry(
  database: PoseDeckDB,
  entity: OutboxEntity,
  serverRecord: unknown,
): Promise<void> {
  // A delete has no canonical record to merge; for images/guests the engine's
  // delete already removed the row locally. For create/update we merge the
  // server record (carrying canonical created/updated).
  if (!serverRecord || typeof serverRecord !== "object") {
    return;
  }
  const rec = serverRecord as AnyServerRecord;
  if (typeof rec.id !== "string" || rec.id === "") {
    return;
  }
  // `force`: this is the server echo of OUR OWN just-confirmed mutation, which
  // carries the SAME `client_updated_at` we sent — a tie under LWW that would be
  // skipped, leaving the server-canonical created/updated/id unwritten. For our
  // own confirmed record the server values are authoritative, so bypass LWW and
  // write them directly (ARCHITECTURE.md §4.2 step 5).
  await mergeRecord(database, entity, rec as never, { force: true });
}

/**
 * The LWW clock we sent for a confirmed mutation, read from the queued payload
 * (`client_updated_at` for decks/cards, `changed_at` for card_completions), or
 * `undefined` for non-LWW entities (images/guests) or a delete with no clock.
 * Used to mark the self-echo so a strictly-newer concurrent remote write is not
 * suppressed.
 */
function confirmedClock(entry: OutboxEntry): string | undefined {
  const key = lwwKey(entry.entity);
  if (!key) return undefined;
  const payload = decodeOutboxPayload(entry);
  const v = (payload as Record<string, unknown>)[key];
  return typeof v === "string" ? v : undefined;
}

/** The bootstrapped sync runtime: engine + realtime + self-echo set. */
export interface SyncRuntime {
  engine: SyncEngine;
  realtime: RealtimeManager;
  recentlyConfirmed: RecentlyConfirmed;
}

/**
 * Construct the sync runtime over `database`. Exposed (rather than only the
 * singleton) so tests can build a runtime against a fresh in-memory db.
 */
export function createSyncRuntime(
  database: PoseDeckDB = db,
  opts: {
    provider?: RealtimeProvider;
    fetchAll?: EntityFetcher;
    /** Injectable transport for tests (defaults to the live PB transport). */
    transport?: MutationTransport;
  } = {},
): SyncRuntime {
  const recentlyConfirmed = new RecentlyConfirmed();

  const engine = new SyncEngine({
    db: database,
    transport: opts.transport,
    hooks: {
      reconcile: (entry, serverRecord) =>
        reconcileEntry(database, entry.entity, serverRecord),
      onConfirmed: (entry) => {
        recentlyConfirmed.mark(
          entry.entity,
          entry.recordId,
          confirmedClock(entry),
        );
      },
      rollback: async (entry) => {
        // A dropped create never reached the server: remove the optimistic row.
        // A dropped update/delete leaves the local row as-is (best effort); a
        // subsequent resync reconciles it against the server truth.
        if (entry.type === "create") {
          await database[entry.entity].delete(entry.recordId);
        }
      },
      onError: (entry, reason) => {
        toast({
          variant: "destructive",
          title: "A change could not be saved",
          description: `${entry.entity} ${entry.type} failed (${reason}).`,
        });
      },
      onAuthError: () => {
        // A background outbox send hit a 401: the persisted token is dead.
        // Clear the session the same way the foreground page handlers do
        // (`clearAuthOnUnauthorized`): drop the cached file token and clear the
        // auth store. Clearing the store fires `authStore.onChange`, which the
        // AuthProvider observes to run `stopSync()` and route the user back to
        // /login — so a background-only 401 no longer strands the engine paused
        // with a dead token and no UI signal (SEC-1).
        clearFileToken();
        pb.authStore.clear();
      },
    },
  });

  const realtime = new RealtimeManager({
    db: database,
    provider: opts.provider ?? pocketBaseRealtimeProvider,
    fetchAll: opts.fetchAll ?? pocketBaseFetchAll,
    recentlyConfirmed,
    // Read the live auth store so a `deck_guests` event's guest-vs-owner
    // decision (M5 FIX #1/#2) always uses the current user id.
    currentUserId: () => pb.authStore.record?.id ?? "",
  });

  return { engine, realtime, recentlyConfirmed };
}

/** Process-wide singleton runtime over the shared `db`. */
let runtime: SyncRuntime | null = null;

/** Whether sync is currently started (engine + realtime running). */
let started = false;

/**
 * Start the sync runtime: disable the SDK's default auto-cancellation (so our
 * sequential FIFO sends to the same collection are not aborted), start the
 * engine, then start realtime (subscribe-first → hydrate). Idempotent.
 */
export async function startSync(): Promise<void> {
  if (started) return;
  started = true;
  pb.autoCancellation(false);
  if (!runtime) {
    runtime = createSyncRuntime();
  }
  runtime.engine.start();
  await runtime.realtime.start();
}

/**
 * Stop the sync runtime and wipe the local store. Called on sign-out so a
 * different user (or a re-login) never sees the prior session's data. The
 * realtime manager is epoch-guarded, so a stop mid-start tears down cleanly.
 */
export async function stopSync(): Promise<void> {
  if (!started) return;
  started = false;
  if (runtime) {
    runtime.engine.stop();
    await runtime.realtime.stop();
    runtime.recentlyConfirmed.clear();
  }
  await clearLocalStore(db);
}

/** Wake the engine to drain now (call right after enqueuing a mutation). */
export function wakeSync(): void {
  runtime?.engine.wake();
}

/**
 * Await a full outbox drain pass and resolve once it settles.
 *
 * `SyncEngine.drain()` is single-flight: concurrent callers await the SAME
 * in-flight pass, and the returned promise resolves only after a complete pass
 * (so any pending creates queued before the call have been sent on a healthy
 * connection). Resolves immediately when sync isn't running. Used by the
 * online-only duplicate image-copy post-step, which must wait for the copy
 * cards' `create`s to flush before it can attach images to them server-side.
 */
export async function drainSync(): Promise<void> {
  if (!runtime) return;
  await runtime.engine.drain();
}

/** Re-run a reconciling hydrate (e.g. manual refresh). */
export async function resync(): Promise<void> {
  if (!started || !runtime) return;
  await hydrateFromServer(db, pocketBaseFetchAll);
}

/** Test seam: whether the singleton runtime is currently started. */
export function isSyncStarted(): boolean {
  return started;
}
