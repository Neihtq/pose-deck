/**
 * TypeScript interfaces for the PocketBase collections.
 *
 * These MUST mirror ARCHITECTURE.md §3 exactly. Do not add fields beyond
 * what is documented there. The data model is LOCKED.
 *
 * Field naming follows PocketBase conventions:
 *  - `id` is the PocketBase-generated record id.
 *  - `created` / `updated` are server-managed datetimes (ISO 8601 strings).
 *  - relation fields hold the related record's id (string).
 *  - datetimes are ISO 8601 strings (PocketBase serializes them as such);
 *    empty / unset datetimes are represented as "".
 */

/** ISO 8601 datetime string as serialized by PocketBase. `""` when unset. */
export type ISODateString = string;

/** Fields present on every PocketBase record. */
export interface BaseRecord {
  id: string;
  /** Collection id, included by the SDK on fetched records. */
  collectionId?: string;
  /** Collection name, included by the SDK on fetched records. */
  collectionName?: string;
}

/** §3.1 `users` (built into PocketBase auth). */
export interface User extends BaseRecord {
  email: string;
  /** Display name. */
  name: string;
  created: ISODateString;
  updated: ISODateString;
  /** PocketBase auth flag; present on the auth collection. */
  verified?: boolean;
}

/** §3.2 `decks`. */
export interface Deck extends BaseRecord {
  /** relation → users (required). */
  owner: string;
  /** required, max 200. */
  name: string;
  /** optional. */
  shoot_date: ISODateString;
  /** for last-write-wins conflict resolution. */
  client_updated_at: ISODateString;
  created: ISODateString;
  updated: ISODateString;
  /** optional, soft-delete. */
  deleted_at: ISODateString;
}

/** §3.3 `cards`. */
export interface Card extends BaseRecord {
  /** relation → decks (required, cascade-delete). */
  deck: string;
  /** for ordering; gaps allowed (integers like 1000, 2000, …). */
  position: number;
  /** required, max 200. */
  title: string;
  /** optional. */
  time_slot: string;
  /** optional. */
  subjects: string;
  /** optional. */
  direction: string;
  /** optional, no length cap. */
  notes: string;
  client_updated_at: ISODateString;
  created: ISODateString;
  updated: ISODateString;
  /** optional, soft-delete. */
  deleted_at: ISODateString;
}

/** §3.4 `card_images`. */
export interface CardImage extends BaseRecord {
  /** relation → cards (required, cascade-delete). */
  card: string;
  /** for ordering within a card. */
  position: number;
  /** PocketBase file field — stored filename (max 1 file per record). */
  file: string;
  created: ISODateString;
}

/** §3.5 `deck_guests`. Composite unique: (deck, user). */
export interface DeckGuest extends BaseRecord {
  /** relation → decks. */
  deck: string;
  /** relation → users. */
  user: string;
  granted_at: ISODateString;
}

/** Per-user shoot progress state (§3.6). */
export type CardCompletionState = "done" | "skipped" | "pending";

/** §3.6 `card_completions`. Composite unique: (card, user). */
export interface CardCompletion extends BaseRecord {
  /** relation → cards. */
  card: string;
  /** relation → users. */
  user: string;
  state: CardCompletionState;
  changed_at: ISODateString;
}

/** Collection name → record type. Keep keys aligned with PocketBase. */
export interface CollectionRecordMap {
  users: User;
  decks: Deck;
  cards: Card;
  card_images: CardImage;
  deck_guests: DeckGuest;
  card_completions: CardCompletion;
}

export type CollectionName = keyof CollectionRecordMap;

const CARD_COMPLETION_STATES: readonly CardCompletionState[] = [
  "done",
  "skipped",
  "pending",
];

/** Type guard: is the value a valid `card_completions.state`? */
export function isCardCompletionState(
  value: unknown,
): value is CardCompletionState {
  return (
    typeof value === "string" &&
    (CARD_COMPLETION_STATES as readonly string[]).includes(value)
  );
}

/** Type guard: has the record been soft-deleted (non-empty `deleted_at`)? */
export function isSoftDeleted(
  record: Pick<Deck | Card, "deleted_at">,
): boolean {
  return typeof record.deleted_at === "string" && record.deleted_at !== "";
}
