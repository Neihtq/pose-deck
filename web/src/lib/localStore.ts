/**
 * Dexie-backed local store: the web client's source of truth (M3 sync).
 *
 * The UI reads from Dexie via live queries; the sync engine and realtime layer
 * write into Dexie. This module owns:
 *  - live read queries that re-express the PocketBase list filters the app used
 *    to issue directly (so the grouped deck list, trash view, and card lists
 *    behave identically offline);
 *  - `mergeRecord` — the SINGLE last-write-wins merge used by realtime events,
 *    the sync engine's post-2xx reconcile, AND the initial server hydration, so
 *    all three paths share one conflict-resolution rule (ARCHITECTURE.md §4.3);
 *  - `hydrateFromServer` — a reconciling backfill that adds/updates rows via
 *    `mergeRecord` and prunes local rows the server no longer returns;
 *  - `clearLocalStore` — wipe on sign-out.
 *
 * Per-entity LWW (data model is LOCKED — types.ts):
 *  - decks, cards     → order by `client_updated_at`, fall back to server
 *                       `updated` when the client clock is empty; ties skip.
 *  - card_completions → order by `changed_at`.
 *  - card_images, deck_guests → NO clock: create = insert-by-id, delete =
 *    hard remove-by-id; never overwrite a present local row with an echo.
 */
import type { OutboxEntity, PoseDeckDB } from "./db";
import { lwwKey } from "./serverEntities";
import type {
  Card,
  CardCompletion,
  CardImage,
  Deck,
  DeckGuest,
} from "./types";

/** A stored record is any of our collection row shapes (all have `id`). */
type AnyRecord = Deck | Card | CardImage | DeckGuest | CardCompletion;

/** Dexie table accessor for an entity. */
function tableFor(db: PoseDeckDB, entity: OutboxEntity) {
  switch (entity) {
    case "decks":
      return db.decks;
    case "cards":
      return db.cards;
    case "card_images":
      return db.card_images;
    case "card_completions":
      return db.card_completions;
    case "deck_guests":
      return db.deck_guests;
  }
}

/**
 * Compare two records' ordering clocks for LWW. Returns true if `incoming`
 * should win over `local`.
 *
 * - For LWW entities (decks/cards/card_completions): compare the clock field;
 *   an empty incoming clock falls back to the server `updated` field (only
 *   decks/cards have it); equal clocks → incoming does NOT win (skip, avoids
 *   thrash and self-echo overwrite).
 * - For non-LWW entities (images/guests): there is no clock — `incoming` always
 *   "wins" in the sense that create/update is an idempotent upsert-by-id; the
 *   caller handles delete as a hard remove. (We never call this to overwrite a
 *   present image/guest row with a partial echo — see `mergeRecord`.)
 */
export function incomingWins(
  entity: OutboxEntity,
  local: AnyRecord | undefined,
  incoming: AnyRecord,
): boolean {
  if (!local) return true;
  const key = lwwKey(entity);
  if (!key) {
    // No clock: treat as idempotent upsert; an existing row is overwritten only
    // by a full record (callers pass full server records here).
    return true;
  }
  const localClock = readClock(local, key);
  const incomingClock = readClock(incoming, key);
  // Empty incoming clock → fall back to server `updated` (decks/cards only).
  if (incomingClock === "") {
    const li = readClock(local, "updated");
    const ii = readClock(incoming, "updated");
    return ii > li;
  }
  if (localClock === "") return true;
  // Strictly newer wins; ties skip (do not re-apply identical/echoed state).
  return incomingClock > localClock;
}

function readClock(record: AnyRecord, key: string): string {
  const v = (record as unknown as Record<string, unknown>)[key];
  return typeof v === "string" ? v : "";
}

/**
 * Merge one server/realtime record into Dexie under the LWW rule. Used by
 * realtime events, post-2xx reconcile, and hydration alike.
 *
 * `deleted` marks a hard-delete event (images/guests, or a realtime `delete`
 * action): the row is removed regardless of clocks. Soft-deletes for
 * decks/cards arrive as ordinary updates with a non-empty `deleted_at` and flow
 * through the normal LWW path (the row stays, the UI filters it out).
 *
 * `force` bypasses the LWW rule and writes `record` unconditionally. The post-2xx
 * reconcile uses this: the server echo of our OWN confirmed mutation carries the
 * SAME `client_updated_at` we sent, which is a tie under LWW and would otherwise
 * be skipped — so the server-canonical `created`/`updated`/`id` would never land
 * in Dexie (ARCHITECTURE.md §4.2 step 5). For our own confirmed record the
 * server values are authoritative, so we write them directly.
 */
export async function mergeRecord(
  db: PoseDeckDB,
  entity: OutboxEntity,
  record: AnyRecord,
  opts: { deleted?: boolean; force?: boolean } = {},
): Promise<void> {
  const table = tableFor(db, entity);
  if (opts.deleted) {
    await table.delete(record.id);
    return;
  }
  if (opts.force) {
    await table.put(record as never);
    return;
  }
  const local = (await table.get(record.id)) as AnyRecord | undefined;
  if (incomingWins(entity, local, record)) {
    await table.put(record as never);
  }
}

/** Bulk-merge a set of records for one entity (used by hydration/resync). */
export async function mergeMany(
  db: PoseDeckDB,
  entity: OutboxEntity,
  records: AnyRecord[],
): Promise<void> {
  for (const r of records) {
    await mergeRecord(db, entity, r);
  }
}

/**
 * Reconciling backfill for one entity: merge the authoritative `serverRecords`
 * via LWW, then DELETE any local rows whose id is absent from the server set.
 * Pruning is essential for hard-deletes (card_images) and revokes (deck_guests)
 * that produce no soft-delete tombstone — an additive merge would resurrect
 * them. `keepIds` lets callers exempt rows that are still pending in the outbox
 * (so we don't prune an optimistic create the server hasn't seen yet).
 *
 * `lateKeep`, if provided, is evaluated IMMEDIATELY before the destructive
 * `bulkDelete` and unioned into the exemption set. This closes a
 * time-of-check/time-of-use window: the caller computes `keepIds` up front, but
 * the server fetch + merge are async and can take seconds, during which the user
 * may create a new record. Without a late re-check, that brand-new optimistic
 * row — created after `keepIds` was snapshotted — is absent from the (stale)
 * server set and not in `keepIds`, so it would be wrongly pruned. Re-reading the
 * live exemptions at prune time keeps just-created rows safe.
 */
export async function reconcileEntity(
  db: PoseDeckDB,
  entity: OutboxEntity,
  serverRecords: AnyRecord[],
  keepIds: ReadonlySet<string> = new Set(),
  lateKeep?: () => Promise<ReadonlySet<string>> | ReadonlySet<string>,
): Promise<void> {
  await mergeMany(db, entity, serverRecords);
  const serverIds = new Set(serverRecords.map((r) => r.id));
  const table = tableFor(db, entity);
  const localIds = (await table.toCollection().primaryKeys()) as string[];
  let exempt: ReadonlySet<string> = keepIds;
  if (lateKeep) {
    const late = await lateKeep();
    const union = new Set(keepIds);
    for (const id of late) union.add(id);
    exempt = union;
  }
  const toPrune = localIds.filter(
    (id) => !serverIds.has(id) && !exempt.has(id),
  );
  if (toPrune.length > 0) {
    await table.bulkDelete(toPrune);
  }
}

/**
 * Ids of records that still have a pending outbox mutation, so a reconciling
 * resync does not prune an optimistic create the server hasn't acked yet.
 */
export async function pendingRecordIds(
  db: PoseDeckDB,
  entity: OutboxEntity,
): Promise<Set<string>> {
  const entries = await db.outbox.where("entity").equals(entity).toArray();
  return new Set(entries.map((e) => e.recordId));
}

/**
 * Short-TTL set of just-uploaded `card_images` ids that must NOT be pruned by a
 * reconciling resync that races ahead of the server list.
 *
 * Images are PocketBase-direct (never enqueued to the outbox — see
 * imageApi.ts), so `pendingRecordIds("card_images")` is always empty and cannot
 * exempt a fresh upload. If a resync/reconnect captured its `getFullList`
 * snapshot BEFORE an upload's server create committed but runs its prune AFTER
 * the optimistic Dexie `put`, `reconcileEntity` would delete the new row. We
 * record each uploaded id here for a short window so `hydrateFromServer` exempts
 * it; the row then converges to the server truth on the next (post-create)
 * resync once the TTL lapses. Module-level (not per-db) because the live app has
 * a single shared `db`; the TTL bounds memory and lets the set stay small.
 */
const recentlyUploadedImageIds = new Map<string, number>();
const RECENT_UPLOAD_TTL_MS = 30_000;

/** Mark a just-uploaded `card_images` id so a racing resync won't prune it. */
export function markRecentlyUploadedImage(
  id: string,
  now: () => number = () => Date.now(),
): void {
  recentlyUploadedImageIds.set(id, now() + RECENT_UPLOAD_TTL_MS);
}

/** The set of un-expired recently-uploaded image ids (lazily evicting). */
export function recentlyUploadedImageKeepIds(
  now: () => number = () => Date.now(),
): Set<string> {
  const t = now();
  const live = new Set<string>();
  for (const [id, expiry] of recentlyUploadedImageIds) {
    if (expiry < t) {
      recentlyUploadedImageIds.delete(id);
    } else {
      live.add(id);
    }
  }
  return live;
}

/** Test seam: forget all recently-uploaded image marks. */
export function clearRecentlyUploadedImages(): void {
  recentlyUploadedImageIds.clear();
}

/**
 * Short-TTL set of just-created OPTIMISTIC record ids per entity (decks/cards)
 * that must NOT be pruned by a reconciling resync whose server snapshot
 * predates the create's server commit.
 *
 * `pendingRecordIds` already exempts an optimistic create while its outbox
 * entry is queued. But there is a race once the create is CONFIRMED and the
 * outbox entry deleted: an in-flight `hydrateFromServer` whose `getFullList`
 * snapshot was captured BEFORE the server committed the insert will not see the
 * new id, and — now that it is no longer "pending" — `reconcileEntity` would
 * prune the freshly-created local row (deck → "Deck not found"; card → vanishes
 * from the deck). This is the deck/card analogue of the documented
 * `card_images` race; we protect against it with the same mark-on-create +
 * consult-in-hydrate mechanism. The row converges to server truth on the next
 * resync once the TTL lapses. Module-level because the live app shares one `db`.
 */
const recentlyCreatedIds: Record<string, Map<string, number>> = {
  decks: new Map(),
  cards: new Map(),
  // deck_guests: an optimistic grant is enqueued like a deck/card create, so it
  // is subject to the same create-prune race (a hydrate whose server snapshot
  // predates the grant's commit would prune the fresh local row). Give it a
  // bucket so `markRecentlyCreated('deck_guests', id)` exempts it (FIX #8).
  deck_guests: new Map(),
};
const RECENT_CREATE_TTL_MS = 30_000;

/**
 * Mark a just-created optimistic `decks`/`cards`/`deck_guests` id so a racing
 * resync whose snapshot predates the server commit won't prune it. No-op for
 * entities without a bucket (images use their own mark; completions are never
 * optimistically created through this path).
 */
export function markRecentlyCreated(
  entity: OutboxEntity,
  id: string,
  now: () => number = () => Date.now(),
): void {
  const bucket = recentlyCreatedIds[entity];
  if (bucket) {
    bucket.set(id, now() + RECENT_CREATE_TTL_MS);
  }
}

/** Un-expired recently-created ids for an entity (lazily evicting). */
export function recentlyCreatedKeepIds(
  entity: OutboxEntity,
  now: () => number = () => Date.now(),
): Set<string> {
  const bucket = recentlyCreatedIds[entity];
  const live = new Set<string>();
  if (!bucket) return live;
  const t = now();
  for (const [id, expiry] of bucket) {
    if (expiry < t) {
      bucket.delete(id);
    } else {
      live.add(id);
    }
  }
  return live;
}

/** Test seam: forget all recently-created marks (all entities). */
export function clearRecentlyCreated(): void {
  for (const bucket of Object.values(recentlyCreatedIds)) {
    bucket.clear();
  }
}

/** The five data collections we mirror + sync, in dependency order. */
export const SYNCED_ENTITIES: readonly OutboxEntity[] = [
  "decks",
  "cards",
  "card_images",
  "deck_guests",
  "card_completions",
] as const;

/**
 * A fetcher that returns ALL viewable records for an entity (across pages),
 * including soft-deleted ones (so trashed decks reconcile into the trash view).
 * Injected so this stays unit-testable without a live PocketBase.
 */
export type EntityFetcher = (entity: OutboxEntity) => Promise<AnyRecord[]>;

/**
 * Reconciling full hydration from the server for all synced entities. Each
 * entity is merged via LWW and pruned against the server id-set, exempting ids
 * with pending local mutations. Safe to run on login and on realtime reconnect.
 */
export async function hydrateFromServer(
  db: PoseDeckDB,
  fetchAll: EntityFetcher,
): Promise<void> {
  for (const entity of SYNCED_ENTITIES) {
    const records = await fetchAll(entity);
    // The exemption set is re-read RIGHT BEFORE the prune (via `lateKeep`), not
    // captured here: `fetchAll` may take seconds, and a record the user creates
    // during that window would be absent from this (now-stale) server snapshot.
    // Re-reading pending-outbox + recently-created/uploaded ids at prune time
    // keeps those just-created optimistic rows from being wrongly pruned (see
    // reconcileEntity's `lateKeep` and `markRecentlyCreated`).
    const liveKeep = async (): Promise<ReadonlySet<string>> => {
      const keep = await pendingRecordIds(db, entity);
      // Images are PB-direct (never in the outbox), so exempt any just-uploaded
      // image whose server create may not be in this snapshot yet.
      if (entity === "card_images") {
        for (const id of recentlyUploadedImageKeepIds()) keep.add(id);
      }
      // Decks/cards: exempt freshly-created optimistic rows whose server commit
      // may post-date this snapshot (covers both the still-queued window and the
      // gap after the create is confirmed + dequeued).
      for (const id of recentlyCreatedKeepIds(entity)) keep.add(id);
      return keep;
    };
    await reconcileEntity(db, entity, records, undefined, liveKeep);
  }
}

/** Remove every locally-stored row + queued mutation (sign-out). */
export async function clearLocalStore(db: PoseDeckDB): Promise<void> {
  await Promise.all([
    db.decks.clear(),
    db.cards.clear(),
    db.card_images.clear(),
    db.card_completions.clear(),
    db.deck_guests.clear(),
    db.outbox.clear(),
    db._meta.clear(),
    // Offline-pin tables (M3 STEP 6): a different user must never inherit the
    // prior session's cached image bytes or pin set.
    db.image_blobs.clear(),
    db.pinned_decks.clear(),
  ]);
}

// ---------------------------------------------------------------------------
// Live read queries (re-express the PocketBase list filters the app used).
// These return plain arrays; callers wrap them with `liveQuery`/useLiveQuery.
// ---------------------------------------------------------------------------

const isLive = (r: { deleted_at: string }) => r.deleted_at === "";

/** Non-soft-deleted decks (grouping/sorting happens in the UI layer). */
export async function liveDecks(db: PoseDeckDB): Promise<Deck[]> {
  return (await db.decks.toArray()).filter(isLive);
}

/**
 * Soft-deleted decks the given user OWNS (trash view), newest-deleted first.
 *
 * Scoped to `ownerId` (FIX #3): a guest's mirror may hold an owner's trashed
 * SHARED deck (the decks listRule still returns it to a guest), but a guest
 * must never see it in their Trash — nor be able to issue a restore PATCH that
 * the server would 403. Only the owner's own trashed decks belong in Trash.
 */
export async function liveTrashedDecks(
  db: PoseDeckDB,
  ownerId: string,
): Promise<Deck[]> {
  return (await db.decks.toArray())
    .filter((d) => d.deleted_at !== "" && d.owner === ownerId)
    .sort((a, b) => (a.deleted_at < b.deleted_at ? 1 : a.deleted_at > b.deleted_at ? -1 : 0));
}

/**
 * A deck's guests (sharing), ordered by `granted_at`. The listRule already
 * scopes the mirrored rows to owner+guest visibility; this just re-expresses
 * the per-deck filter for the owner's Share dialog.
 */
export async function liveDeckGuests(
  db: PoseDeckDB,
  deckId: string,
): Promise<DeckGuest[]> {
  return (await db.deck_guests.where("deck").equals(deckId).toArray()).sort(
    (a, b) => (a.granted_at < b.granted_at ? -1 : a.granted_at > b.granted_at ? 1 : 0),
  );
}

/** A single live deck by id, or undefined if missing/soft-deleted. */
export async function liveDeck(
  db: PoseDeckDB,
  id: string,
): Promise<Deck | undefined> {
  const d = await db.decks.get(id);
  return d && isLive(d) ? d : undefined;
}

/** A deck's non-soft-deleted cards, ordered by position. */
export async function liveCards(
  db: PoseDeckDB,
  deckId: string,
): Promise<Card[]> {
  return (await db.cards.where("deck").equals(deckId).toArray())
    .filter(isLive)
    .sort((a, b) => a.position - b.position);
}

/** A card's images, ordered by position. */
export async function liveCardImages(
  db: PoseDeckDB,
  cardId: string,
): Promise<CardImage[]> {
  return (await db.card_images.where("card").equals(cardId).toArray()).sort(
    (a, b) => a.position - b.position,
  );
}
