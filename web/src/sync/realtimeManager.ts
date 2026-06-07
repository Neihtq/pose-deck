/**
 * Realtime subscription + merge lifecycle (M3 sync, ARCHITECTURE.md §4.4).
 *
 * On start the manager:
 *  1. opens a `'*'` realtime subscription on each of the five synced
 *     collections FIRST (ARCHITECTURE.md §4.4 + invariant: subscribe before
 *     resync so no event is missed in the gap), then
 *  2. runs a reconciling full hydrate from the server.
 *
 * Each incoming `{action, record}` event is applied to Dexie through the shared
 * LWW `mergeRecord` (so realtime, reconcile, and hydrate agree), except events
 * that match a just-confirmed local mutation, which are suppressed
 * (self-echo). `delete` actions are hard removes; `create`/`update` go through
 * LWW (a soft-deleted deck/card arrives as an `update` with `deleted_at` set).
 *
 * The async `start()` is epoch-guarded: a `stop()` during start (e.g. a fast
 * sign-out) increments the epoch so any in-flight subscribe whose epoch is
 * stale is immediately unsubscribed, preventing a leaked subscription.
 */
import type { OutboxEntity, PoseDeckDB } from "@/lib/db";
import {
  type EntityFetcher,
  SYNCED_ENTITIES,
  hydrateFromServer,
  mergeRecord,
} from "@/lib/localStore";
import type { RecentlyConfirmed } from "./recentlyConfirmed";

/** A realtime event as delivered by the PocketBase SDK. */
export interface RealtimeEvent {
  action: string; // "create" | "update" | "delete"
  record: { id: string } & Record<string, unknown>;
}

/** Unsubscribe handle. */
export type Unsubscribe = () => Promise<void>;

/**
 * Subscription provider, injected so tests can drive events without a live
 * server. `subscribe(entity, cb)` resolves once the subscription is open.
 */
export interface RealtimeProvider {
  subscribe(
    entity: OutboxEntity,
    cb: (event: RealtimeEvent) => void,
  ): Promise<Unsubscribe>;
}

export interface RealtimeManagerOptions {
  db: PoseDeckDB;
  provider: RealtimeProvider;
  fetchAll: EntityFetcher;
  recentlyConfirmed?: RecentlyConfirmed;
  /** Called when an event is applied (for tests / metrics). */
  onApplied?(entity: OutboxEntity, event: RealtimeEvent): void;
}

export class RealtimeManager {
  private readonly db: PoseDeckDB;
  private readonly provider: RealtimeProvider;
  private readonly fetchAll: EntityFetcher;
  private readonly recentlyConfirmed?: RecentlyConfirmed;
  private readonly onApplied?: (e: OutboxEntity, ev: RealtimeEvent) => void;

  private unsubscribes: Unsubscribe[] = [];
  private started = false;
  /** Bumped on every start/stop so a stale in-flight start can detect itself. */
  private epoch = 0;

  constructor(opts: RealtimeManagerOptions) {
    this.db = opts.db;
    this.provider = opts.provider;
    this.fetchAll = opts.fetchAll;
    this.recentlyConfirmed = opts.recentlyConfirmed;
    this.onApplied = opts.onApplied;
  }

  get isStarted(): boolean {
    return this.started;
  }

  /**
   * Subscribe to all collections, then hydrate. Idempotent: a second call while
   * started is a no-op. Epoch-guarded against a concurrent stop().
   */
  async start(): Promise<void> {
    if (this.started) return;
    this.started = true;
    const epoch = ++this.epoch;

    const subs: Unsubscribe[] = [];
    for (const entity of SYNCED_ENTITIES) {
      const unsub = await this.provider.subscribe(entity, (event) =>
        this.handleEvent(entity, event),
      );
      // A stop() landed mid-start: tear down what we opened and bail.
      if (epoch !== this.epoch) {
        await unsub();
        for (const u of subs) await u();
        return;
      }
      subs.push(unsub);
    }
    this.unsubscribes = subs;

    // Subscriptions are live; backfill anything that changed before they opened.
    await hydrateFromServer(this.db, this.fetchAll);
    if (epoch !== this.epoch) {
      // Signed out during hydrate — unwind.
      await this.teardown();
    }
  }

  /** Run a reconciling resync (e.g. after a realtime reconnect). */
  async resync(): Promise<void> {
    if (!this.started) return;
    await hydrateFromServer(this.db, this.fetchAll);
  }

  /** Unsubscribe everything and reset. Safe to call when not started. */
  async stop(): Promise<void> {
    this.epoch++; // invalidate any in-flight start()
    this.started = false;
    await this.teardown();
  }

  private async teardown(): Promise<void> {
    const subs = this.unsubscribes;
    this.unsubscribes = [];
    for (const u of subs) {
      try {
        await u();
      } catch {
        // best-effort unsubscribe
      }
    }
  }

  private handleEvent(entity: OutboxEntity, event: RealtimeEvent): void {
    void this.applyEvent(entity, event);
  }

  private async applyEvent(
    entity: OutboxEntity,
    event: RealtimeEvent,
  ): Promise<void> {
    // Suppress the echo of our own just-confirmed mutation.
    if (this.recentlyConfirmed?.shouldSuppress(entity, event.record.id)) {
      return;
    }
    await mergeRecord(this.db, entity, event.record as never, {
      deleted: event.action === "delete",
    });
    this.onApplied?.(entity, event);
  }
}
