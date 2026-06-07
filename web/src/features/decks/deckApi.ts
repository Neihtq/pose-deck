/**
 * Data-access primitives for `decks` (M3 local-first).
 *
 * As of M3 these are local-first: a mutation writes the optimistic row into
 * Dexie immediately and enqueues a coalesced outbox entry (drained by the sync
 * engine). Reads come from Dexie live queries in the pages (`liveDecks` etc.),
 * so this module no longer exposes `listDecks`/`getDeck` fetchers — the UI never
 * blocks on the network for a read.
 *
 * Conventions (see web CLAUDE.md / ARCHITECTURE.md §3.2, §4.2):
 *  - Creates mint a client-supplied PB-shaped id (`newClientId`) so the record
 *    identity is stable across the optimistic write and the eventual server
 *    insert (no temp-id reconciliation).
 *  - Every mutation stamps `client_updated_at` with the current ISO time (LWW).
 *  - Soft delete = set `deleted_at`; we never hard-delete decks.
 *  - `owner` is set explicitly from the authenticated user: the deck
 *    `createRule` only authorizes the request and no server hook populates the
 *    required `owner` relation (a load-bearing M1 fix — do not drop).
 */
import { db } from "@/lib/db";
import { newClientId } from "@/lib/ids";
import { enqueueCoalesced } from "@/lib/outbox";
import { pb } from "@/lib/pocketbase";
import { wakeSync } from "@/sync";
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
 * Build a fully-populated optimistic deck row. Server-managed `created`/
 * `updated` are seeded from the client clock; the sync engine reconciles the
 * canonical values into Dexie on the create's 2xx.
 */
function optimisticDeck(input: {
  id: string;
  owner: string;
  name: string;
  shoot_date: ISODateString;
  client_updated_at: ISODateString;
}): Deck {
  return {
    id: input.id,
    owner: input.owner,
    name: input.name,
    shoot_date: input.shoot_date,
    deleted_at: "",
    client_updated_at: input.client_updated_at,
    created: input.client_updated_at,
    updated: input.client_updated_at,
  };
}

/**
 * Create a new deck for the current user. Writes the optimistic row into Dexie
 * and enqueues a `create` outbox entry; returns the optimistic record.
 */
export async function createDeck(input: CreateDeckInput): Promise<Deck> {
  const owner = currentUserId();
  const stamp = nowIso();
  const deck = optimisticDeck({
    id: newClientId(),
    owner,
    name: input.name,
    shoot_date: input.shoot_date ?? "",
    client_updated_at: stamp,
  });
  await db.decks.put(deck);
  await enqueueCoalesced(db, {
    type: "create",
    entity: "decks",
    recordId: deck.id,
    payload: {
      owner: deck.owner,
      name: deck.name,
      shoot_date: deck.shoot_date,
      deleted_at: "",
      client_updated_at: stamp,
    },
  });
  wakeSync();
  return deck;
}

/** Rename a deck (optimistic Dexie write + coalesced update enqueue). */
export async function renameDeck(id: string, name: string): Promise<Deck> {
  const stamp = nowIso();
  const existing = await db.decks.get(id);
  const updated: Deck = {
    ...(existing as Deck),
    id,
    name,
    client_updated_at: stamp,
  };
  await db.decks.put(updated);
  await enqueueCoalesced(db, {
    type: "update",
    entity: "decks",
    recordId: id,
    payload: { name, client_updated_at: stamp },
  });
  wakeSync();
  return updated;
}

/** Soft-delete a deck (move to trash). Never hard-deletes. */
export async function softDeleteDeck(id: string): Promise<Deck> {
  const stamp = nowIso();
  const existing = await db.decks.get(id);
  const updated: Deck = {
    ...(existing as Deck),
    id,
    deleted_at: stamp,
    client_updated_at: stamp,
  };
  await db.decks.put(updated);
  await enqueueCoalesced(db, {
    type: "update",
    entity: "decks",
    recordId: id,
    payload: { deleted_at: stamp, client_updated_at: stamp },
  });
  wakeSync();
  return updated;
}

/** Restore a soft-deleted deck (clear `deleted_at`). */
export async function restoreDeck(id: string): Promise<Deck> {
  const stamp = nowIso();
  const existing = await db.decks.get(id);
  const updated: Deck = {
    ...(existing as Deck),
    id,
    deleted_at: "",
    client_updated_at: stamp,
  };
  await db.decks.put(updated);
  await enqueueCoalesced(db, {
    type: "update",
    entity: "decks",
    recordId: id,
    payload: { deleted_at: "", client_updated_at: stamp },
  });
  wakeSync();
  return updated;
}

/**
 * Duplicate a deck (poor-man's templates, DESIGN.md §3.3).
 *
 * Reads the source deck + its live cards from Dexie, then creates a fresh deck
 * (name suffixed with "(copy)", no `shoot_date`) and a copy of every
 * non-soft-deleted card with freshly striped integer-gap positions, preserving
 * order. All writes are optimistic (Dexie + outbox); images and completions are
 * not copied (DESIGN.md §3.3). Duplication is only valid for *live* source
 * decks — a trashed source throws so it can't be resurrected outside restore.
 */
export async function duplicateDeck(id: string): Promise<Deck> {
  const source = await db.decks.get(id);
  if (!source || source.deleted_at !== "") {
    throw new Error("Cannot duplicate a deck that is in Trash.");
  }

  const owner = currentUserId();
  const stamp = nowIso();
  const copy = optimisticDeck({
    id: newClientId(),
    owner,
    name: `${source.name} (copy)`,
    shoot_date: "",
    client_updated_at: stamp,
  });
  await db.decks.put(copy);
  await enqueueCoalesced(db, {
    type: "create",
    entity: "decks",
    recordId: copy.id,
    payload: {
      owner,
      name: copy.name,
      shoot_date: "",
      deleted_at: "",
      client_updated_at: stamp,
    },
  });

  const sourceCards = (await db.cards.where("deck").equals(id).toArray())
    .filter((c) => c.deleted_at === "")
    .sort((a, b) => a.position - b.position);

  let position = POSITION_GAP;
  for (const card of sourceCards) {
    const cardStamp = nowIso();
    const newCard: Card = {
      id: newClientId(),
      deck: copy.id,
      position,
      title: card.title,
      time_slot: card.time_slot,
      subjects: card.subjects,
      direction: card.direction,
      notes: card.notes,
      deleted_at: "",
      client_updated_at: cardStamp,
      created: cardStamp,
      updated: cardStamp,
    };
    await db.cards.put(newCard);
    await enqueueCoalesced(db, {
      type: "create",
      entity: "cards",
      recordId: newCard.id,
      payload: {
        deck: copy.id,
        position,
        title: newCard.title,
        time_slot: newCard.time_slot,
        subjects: newCard.subjects,
        direction: newCard.direction,
        notes: newCard.notes,
        deleted_at: "",
        client_updated_at: cardStamp,
      },
    });
    position += POSITION_GAP;
  }

  wakeSync();
  return copy;
}

/** Re-exported for callers/tests that need the canonical gap value. */
export { POSITION_GAP, type Card };
