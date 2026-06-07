/**
 * Dexie (IndexedDB) local store schema.
 *
 * Per ARCHITECTURE.md §4.1, the web client mirrors the same shape as iOS:
 * tables `decks`, `cards`, `card_images`, `card_completions`, plus an
 * `outbox` table for the offline mutation queue (§4.2).
 *
 * This file is SCHEMA / TABLE DEFINITIONS ONLY. No sync logic, no outbox
 * processor — those land in M3 (PROJECT_PLAN.md §3, M3).
 */
import Dexie, { type EntityTable } from "dexie";

import type { Card, CardCompletion, CardImage, Deck, DeckGuest } from "./types";

/** Kind of mutation queued in the outbox. */
export type OutboxOperation = "create" | "update" | "delete";

/**
 * Processing state of an outbox entry, used by the FIFO drain loop.
 *  - `pending`: eligible to send once `next_attempt_at` has passed.
 *  - `inflight`: a send is in progress (single-flight guard).
 */
export type OutboxStatus = "pending" | "inflight";

/** Entity (collection) a queued mutation targets. */
export type OutboxEntity =
  | "decks"
  | "cards"
  | "card_images"
  | "card_completions"
  | "deck_guests";

/**
 * A queued, not-yet-synced local mutation.
 *
 * Mirrors the iOS `OutboxEntry` shape (ARCHITECTURE.md §4.1):
 * id, type, entity, payload (JSON), idempotency_key, local_timestamp,
 * retry_count, last_error.
 */
export interface OutboxEntry {
  /** Auto-incremented local primary key. */
  id?: number;
  /** Mutation kind. */
  type: OutboxOperation;
  /** Target collection. */
  entity: OutboxEntity;
  /** Local id of the affected record (may be a temp id before server ack). */
  recordId: string;
  /** Serialized mutation payload (JSON string). */
  payload: string;
  /** UUID for idempotent server-side replay protection. */
  idempotency_key: string;
  /** Local clock at mutation time (ISO 8601). */
  local_timestamp: string;
  /** Number of send attempts so far. */
  retry_count: number;
  /** Last error message, if a send attempt failed. */
  last_error?: string;
  /** Processing state (FIFO drain). Absent on v1 rows → treated as `pending`. */
  status?: OutboxStatus;
  /**
   * Earliest time (ms epoch) this entry may be (re)attempted. Set when a
   * transient failure schedules a backoff retry; `undefined`/0 = send now.
   */
  next_attempt_at?: number;
}

/**
 * A small key/value table for sync bookkeeping (e.g. per-collection resync
 * cursors). Kept generic so the realtime layer can stash cursors without
 * another schema bump.
 */
export interface SyncMeta {
  /** Meta key, e.g. `"cursor:decks"`. */
  key: string;
  /** Opaque JSON-serializable value. */
  value: string;
}

/** The app's Dexie database with typed tables. */
export class PoseDeckDB extends Dexie {
  decks!: EntityTable<Deck, "id">;
  cards!: EntityTable<Card, "id">;
  card_images!: EntityTable<CardImage, "id">;
  card_completions!: EntityTable<CardCompletion, "id">;
  deck_guests!: EntityTable<DeckGuest, "id">;
  outbox!: EntityTable<OutboxEntry, "id">;
  _meta!: EntityTable<SyncMeta, "key">;

  constructor(name = "pose-deck") {
    super(name);
    this.version(1).stores({
      // Primary key first, then indexed fields used for lookups/sorting.
      decks: "id, owner, shoot_date, deleted_at, client_updated_at",
      cards: "id, deck, position, deleted_at, client_updated_at",
      card_images: "id, card, position",
      card_completions: "id, card, user, state, [card+user]",
      // Auto-increment PK for FIFO processing; index entity + idempotency_key.
      outbox: "++id, entity, recordId, idempotency_key",
    });
    // v2 (M3 sync): the FIFO drain needs to query the queue by status and
    // backoff time, so index those. Add `deck_guests` (mirrored for sharing /
    // realtime) and a `_meta` cursor table. `card_images` is intentionally NOT
    // re-indexed on `updated` — that field does not exist on the collection
    // (ARCHITECTURE.md §3.4); images use insert/hard-delete, not LWW.
    this.version(2).stores({
      deck_guests: "id, deck, user, granted_at",
      outbox: "++id, status, next_attempt_at, entity, recordId, idempotency_key",
      _meta: "key",
    });
  }
}

/** Shared singleton database instance. */
export const db = new PoseDeckDB();
