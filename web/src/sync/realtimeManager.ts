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
import { lwwKey } from "@/lib/serverEntities";
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
  /**
   * The current authenticated user's id, for guest-vs-owner sharing decisions
   * (FIX #1/#2). Injected as a getter so it always reflects the live auth store
   * (a re-auth between events is honoured). Returns `""` when signed out.
   */
  currentUserId?: () => string;
  /** Called when an event is applied (for tests / metrics). */
  onApplied?(entity: OutboxEntity, event: RealtimeEvent): void;
}

export class RealtimeManager {
  private readonly db: PoseDeckDB;
  private readonly provider: RealtimeProvider;
  private readonly fetchAll: EntityFetcher;
  private readonly recentlyConfirmed?: RecentlyConfirmed;
  private readonly currentUserId?: () => string;
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
    this.currentUserId = opts.currentUserId;
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
    // Suppress the echo of our own just-confirmed mutation — but NOT a
    // concurrent remote write that is strictly newer than what we confirmed.
    // Pass the event's LWW clock so a genuinely-newer same-record edit from
    // another writer still flows through mergeRecord's LWW path.
    if (
      this.recentlyConfirmed?.shouldSuppress(
        entity,
        event.record.id,
        incomingClock(entity, event.record),
      )
    ) {
      return;
    }
    await mergeRecord(this.db, entity, event.record as never, {
      deleted: event.action === "delete",
    });

    // Sharing side-effects (M5, FIX #1/#2). A `deck_guests` event that targets
    // the CURRENT user changes which decks they can see; the deck list is
    // Dexie-mirror-backed, so we must reconcile the mirror by hand.
    if (entity === "deck_guests") {
      await this.applyDeckGuestSideEffect(event);
    }

    this.onApplied?.(entity, event);
  }

  /**
   * React to a `deck_guests` realtime event that concerns the current user.
   *
   * FIX #1 (grant): a CREATE granting ME a deck I don't yet mirror locally →
   * resync, so hydration pulls the now-visible deck + its cards + images into
   * Dexie and `liveDecks` re-queries. Gated to the absent-deck case so an echo
   * of a deck I already have doesn't trigger a redundant resync.
   *
   * FIX #2 (revoke): a DELETE revoking ME from a deck whose LOCAL row shows a
   * FOREIGN owner → cascade-evict the deck + its cards + card_images +
   * image_blobs/pin from Dexie so it disappears from my list. FIX #7-web:
   * resolve the owner from the LOCAL deck row FIRST; if the deck row is absent
   * we can't confirm foreign ownership, so do nothing (this also protects an
   * OWNER who revokes their own guest — their deck row's owner is themselves,
   * so it is kept).
   */
  private async applyDeckGuestSideEffect(event: RealtimeEvent): Promise<void> {
    const me = this.currentUserId?.() ?? "";
    if (me === "") return;
    const guestUser = event.record.user;
    if (typeof guestUser !== "string" || guestUser !== me) return;
    const deckId = event.record.deck;
    if (typeof deckId !== "string" || deckId === "") return;

    if (event.action === "create") {
      const deck = await this.db.decks.get(deckId);
      if (!deck) {
        await this.resync();
      }
      return;
    }
    if (event.action === "delete") {
      const deck = await this.db.decks.get(deckId);
      // FIX #7-web: only evict a positively-resolved FOREIGN-owned deck.
      if (deck && deck.owner !== me) {
        await this.cascadeEvictDeck(deckId);
      }
    }
  }

  /**
   * Remove a deck and everything derived from it from the local mirror: the
   * deck row, its cards, those cards' card_images, any cached offline image
   * bytes (`image_blobs`, keyed by card), and the offline pin. Used when the
   * current user loses guest access (FIX #2) — the server stops returning the
   * deck, but with no soft-delete tombstone an additive merge would otherwise
   * leave the stale rows behind.
   */
  private async cascadeEvictDeck(deckId: string): Promise<void> {
    const cards = await this.db.cards.where("deck").equals(deckId).toArray();
    const cardIds = cards.map((c) => c.id);
    for (const cardId of cardIds) {
      await this.db.card_images.where("card").equals(cardId).delete();
      await this.db.image_blobs.where("card").equals(cardId).delete();
    }
    if (cardIds.length > 0) {
      await this.db.cards.bulkDelete(cardIds);
    }
    await this.db.decks.delete(deckId);
    await this.db.pinned_decks.delete(deckId);
  }
}

/**
 * The realtime event's LWW ordering clock for `entity`, or `undefined` for
 * non-LWW entities (images/guests) or a missing/non-string value. Used to let
 * a strictly-newer concurrent remote write escape self-echo suppression.
 */
function incomingClock(
  entity: OutboxEntity,
  record: RealtimeEvent["record"],
): string | undefined {
  const key = lwwKey(entity);
  if (!key) return undefined;
  const v = record[key];
  return typeof v === "string" ? v : undefined;
}
