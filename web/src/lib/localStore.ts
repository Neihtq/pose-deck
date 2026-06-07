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
 */
export async function mergeRecord(
  db: PoseDeckDB,
  entity: OutboxEntity,
  record: AnyRecord,
  opts: { deleted?: boolean } = {},
): Promise<void> {
  const table = tableFor(db, entity);
  if (opts.deleted) {
    await table.delete(record.id);
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
 */
export async function reconcileEntity(
  db: PoseDeckDB,
  entity: OutboxEntity,
  serverRecords: AnyRecord[],
  keepIds: ReadonlySet<string> = new Set(),
): Promise<void> {
  await mergeMany(db, entity, serverRecords);
  const serverIds = new Set(serverRecords.map((r) => r.id));
  const table = tableFor(db, entity);
  const localIds = (await table.toCollection().primaryKeys()) as string[];
  const toPrune = localIds.filter(
    (id) => !serverIds.has(id) && !keepIds.has(id),
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
    const [records, keep] = await Promise.all([
      fetchAll(entity),
      pendingRecordIds(db, entity),
    ]);
    await reconcileEntity(db, entity, records, keep);
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

/** Soft-deleted decks (trash view), newest-deleted first. */
export async function liveTrashedDecks(db: PoseDeckDB): Promise<Deck[]> {
  return (await db.decks.toArray())
    .filter((d) => d.deleted_at !== "")
    .sort((a, b) => (a.deleted_at < b.deleted_at ? 1 : -1));
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
