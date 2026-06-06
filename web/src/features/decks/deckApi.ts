/**
 * Data-access primitives for `decks`.
 *
 * Thin async wrappers around `collections.decks()` (the official PocketBase JS
 * SDK record service). These are the CRUD primitives every deck page builds on.
 *
 * Conventions (see web CLAUDE.md / ARCHITECTURE.md §3.2):
 *  - Every mutation stamps `client_updated_at` with the current ISO time
 *    (last-write-wins prep).
 *  - Soft delete = set `deleted_at` to the current ISO time. We never
 *    hard-delete decks from the UI.
 *  - List queries exclude soft-deleted records via a `deleted_at = ""` filter.
 *
 * For M1 these call PocketBase directly; the Dexie cache / outbox sync lands in
 * M3, so we keep the surface area minimal and typed.
 */
import { collections, pb } from "@/lib/pocketbase";
import type { Card, Deck, ISODateString } from "@/lib/types";

/** Current wall-clock time as an ISO 8601 string. */
function nowIso(): ISODateString {
  return new Date().toISOString();
}

/**
 * The authenticated user's id, for stamping `owner` on create.
 *
 * The deck `createRule` (`@request.auth.id != ""`) only *authorizes* the
 * request — it does not populate the required `owner` relation, and there are
 * no server hooks that do. So the client must set it explicitly or the create
 * fails with `owner: validation_required`.
 */
function currentUserId(): string {
  const id = pb.authStore.record?.id;
  if (typeof id !== "string" || id === "") {
    throw new Error("Cannot create a deck while signed out.");
  }
  return id;
}

/** Integer gap between card positions (1000, 2000, …). */
const POSITION_GAP = 1000;

/** Fields a caller may provide when creating a deck. */
export interface CreateDeckInput {
  /** required, max 200. */
  name: string;
  /** optional ISO 8601 datetime. */
  shoot_date?: ISODateString;
}

/**
 * List the current user's decks that are not soft-deleted.
 *
 * The PocketBase `listRule` (ARCHITECTURE.md §3.2) already scopes results to
 * decks the authenticated user owns *or* has been granted guest access to, so
 * the SDK returns both owner and guest decks. We only filter out the
 * soft-deleted ones here and sort newest-updated first as a stable default
 * (page-level grouping/sorting happens in `deckGrouping`).
 */
export async function listDecks(): Promise<Deck[]> {
  return collections.decks().getFullList({
    filter: 'deleted_at = ""',
    sort: "-updated",
  });
}

/**
 * Fetch a single non-soft-deleted deck by id.
 *
 * The PocketBase `viewRule` mirrors the `listRule` (owner/guest scoping) but
 * has no `deleted_at = ""` condition, so a plain `getOne(id)` would happily
 * return a trashed deck — letting a stale tab/bookmark/direct URL render and
 * edit a record that should only live in Trash. We scope the fetch with
 * `deleted_at = ""` so a soft-deleted deck reads as not-found, matching the
 * list paths and the soft-delete model (DESIGN.md §3).
 */
export async function getDeck(id: string): Promise<Deck> {
  return collections
    .decks()
    .getFirstListItem(pb.filter("id = {:id} && deleted_at = ''", { id }));
}

/**
 * Create a new deck for the current user.
 *
 * `owner` is a required relation that the server does NOT auto-populate, so we
 * set it from the authenticated user. An empty `shoot_date` is sent as `""` to
 * match the PocketBase "unset datetime" representation.
 */
export async function createDeck(input: CreateDeckInput): Promise<Deck> {
  return collections.decks().create({
    owner: currentUserId(),
    name: input.name,
    shoot_date: input.shoot_date ?? "",
    deleted_at: "",
    client_updated_at: nowIso(),
  });
}

/** Rename a deck. */
export async function renameDeck(id: string, name: string): Promise<Deck> {
  return collections.decks().update(id, {
    name,
    client_updated_at: nowIso(),
  });
}

/** Soft-delete a deck (move to trash). Never hard-deletes. */
export async function softDeleteDeck(id: string): Promise<Deck> {
  return collections.decks().update(id, {
    deleted_at: nowIso(),
    client_updated_at: nowIso(),
  });
}

/** Restore a soft-deleted deck (clear `deleted_at`). */
export async function restoreDeck(id: string): Promise<Deck> {
  return collections.decks().update(id, {
    deleted_at: "",
    client_updated_at: nowIso(),
  });
}

/** List the current user's soft-deleted decks (the trash view). */
export async function listTrashedDecks(): Promise<Deck[]> {
  return collections.decks().getFullList({
    filter: 'deleted_at != ""',
    sort: "-deleted_at",
  });
}

/**
 * Duplicate a deck (poor-man's templates, DESIGN.md §3.3).
 *
 * Copies the deck metadata into a fresh deck (name suffixed with "(copy)", no
 * `shoot_date` carried over — the copy is a template starting point) and copies
 * every non-soft-deleted card with freshly striped integer-gap positions,
 * preserving their original order. Card completion state and images are not
 * copied (completions are per-user/permanent per DESIGN.md §3; images are
 * handled by the image-pipeline unit and not duplicated in M1).
 *
 * Duplication is only valid for *live* source decks. `getDeck` already filters
 * out soft-deleted decks, but we also assert it explicitly so a trashed deck
 * can never be resurrected into a fresh live copy outside the restore workflow
 * (DESIGN.md §3.3 / soft-delete model), even if `getDeck`'s scoping changes.
 */
export async function duplicateDeck(id: string): Promise<Deck> {
  const source = await getDeck(id);
  if (source.deleted_at !== "") {
    throw new Error("Cannot duplicate a deck that is in Trash.");
  }

  const copy = await collections.decks().create({
    owner: currentUserId(),
    name: `${source.name} (copy)`,
    shoot_date: "",
    deleted_at: "",
    client_updated_at: nowIso(),
  });

  const sourceCards = await collections.cards().getFullList({
    filter: pb.filter("deck = {:deck} && deleted_at = ''", { deck: id }),
    sort: "position",
  });

  let position = POSITION_GAP;
  for (const card of sourceCards) {
    await collections.cards().create({
      deck: copy.id,
      position,
      title: card.title,
      time_slot: card.time_slot,
      subjects: card.subjects,
      direction: card.direction,
      notes: card.notes,
      deleted_at: "",
      client_updated_at: nowIso(),
    });
    position += POSITION_GAP;
  }

  return copy;
}

/** Re-exported for callers/tests that need the canonical gap value. */
export { POSITION_GAP, type Card };
