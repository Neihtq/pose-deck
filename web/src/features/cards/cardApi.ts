/**
 * Data-access primitives for `cards` (M3 local-first).
 *
 * As of M3 these are local-first: a mutation writes the optimistic row into
 * Dexie immediately and enqueues a coalesced outbox entry (drained by the sync
 * engine). Reads come from Dexie live queries in the pages (`liveCards`), so
 * this module no longer exposes a `listCards` fetcher.
 *
 * Cards live in a flat, ordered list within a deck; ordering uses integer-gap
 * `position` values (1000, 2000, …) (ARCHITECTURE.md §3.3).
 *
 * Conventions (see web CLAUDE.md):
 *  - Creates mint a client-supplied PB-shaped id (`newClientId`).
 *  - Every mutation stamps `client_updated_at` with the current ISO time (LWW).
 *  - Soft delete = set `deleted_at`; never hard-delete.
 */
import { db } from "@/lib/db";
import { newClientId } from "@/lib/ids";
import { enqueueCoalesced } from "@/lib/outbox";
import { wakeSync } from "@/sync";
import type { Card, ISODateString } from "@/lib/types";

/** Integer gap between adjacent card positions. */
export const POSITION_GAP = 1000;

/** Current wall-clock time as an ISO 8601 string. */
function nowIso(): ISODateString {
  return new Date().toISOString();
}

/** Editable card fields a caller may set on create/update. */
export interface CardFields {
  title: string;
  time_slot?: string;
  subjects?: string;
  direction?: string;
  notes?: string;
}

/**
 * Compute the position for a new card appended to the end of a deck.
 *
 * Pure given the existing cards: `last position + POSITION_GAP`, or
 * `POSITION_GAP` when the deck is empty. Exported for direct unit testing.
 */
export function nextPosition(existing: Pick<Card, "position">[]): number {
  if (existing.length === 0) {
    return POSITION_GAP;
  }
  const max = existing.reduce(
    (acc, card) => (card.position > acc ? card.position : acc),
    Number.NEGATIVE_INFINITY,
  );
  return max + POSITION_GAP;
}

/**
 * Create a card at the end of the deck.
 *
 * Computes the next integer-gap position from the deck's live cards in Dexie
 * (not the network), writes the optimistic row, and enqueues a `create`.
 */
export async function createCard(
  deckId: string,
  fields: CardFields,
): Promise<Card> {
  const existing = (await db.cards.where("deck").equals(deckId).toArray())
    .filter((c) => c.deleted_at === "");
  const stamp = nowIso();
  const card: Card = {
    id: newClientId(),
    deck: deckId,
    position: nextPosition(existing),
    title: fields.title,
    time_slot: fields.time_slot ?? "",
    subjects: fields.subjects ?? "",
    direction: fields.direction ?? "",
    notes: fields.notes ?? "",
    deleted_at: "",
    client_updated_at: stamp,
    created: stamp,
    updated: stamp,
  };
  await db.cards.put(card);
  await enqueueCoalesced(db, {
    type: "create",
    entity: "cards",
    recordId: card.id,
    payload: {
      deck: deckId,
      position: card.position,
      title: card.title,
      time_slot: card.time_slot,
      subjects: card.subjects,
      direction: card.direction,
      notes: card.notes,
      deleted_at: "",
      client_updated_at: stamp,
    },
  });
  wakeSync();
  return card;
}

/** Update editable fields on a card. Only provided keys are written. */
export async function updateCard(
  id: string,
  fields: Partial<CardFields>,
): Promise<Card> {
  const stamp = nowIso();
  const patch: Partial<Card> & { client_updated_at: ISODateString } = {
    client_updated_at: stamp,
  };
  if (fields.title !== undefined) patch.title = fields.title;
  if (fields.time_slot !== undefined) patch.time_slot = fields.time_slot;
  if (fields.subjects !== undefined) patch.subjects = fields.subjects;
  if (fields.direction !== undefined) patch.direction = fields.direction;
  if (fields.notes !== undefined) patch.notes = fields.notes;

  const existing = await db.cards.get(id);
  const updated: Card = { ...(existing as Card), id, ...patch };
  await db.cards.put(updated);
  await enqueueCoalesced(db, {
    type: "update",
    entity: "cards",
    recordId: id,
    payload: patch,
  });
  wakeSync();
  return updated;
}

/** Soft-delete a card. Never hard-deletes. */
export async function softDeleteCard(id: string): Promise<Card> {
  const stamp = nowIso();
  const existing = await db.cards.get(id);
  const updated: Card = {
    ...(existing as Card),
    id,
    deleted_at: stamp,
    client_updated_at: stamp,
  };
  await db.cards.put(updated);
  await enqueueCoalesced(db, {
    type: "update",
    entity: "cards",
    recordId: id,
    payload: { deleted_at: stamp, client_updated_at: stamp },
  });
  wakeSync();
  return updated;
}

/**
 * Recompute integer-gap positions from an explicit ordering of card ids.
 *
 * Pure: maps each id to `(index + 1) * POSITION_GAP`. Exported so callers/tests
 * can verify the position math without touching the network.
 */
export function computeReorderedPositions(
  orderedIds: string[],
): Array<{ id: string; position: number }> {
  return orderedIds.map((id, index) => ({
    id,
    position: (index + 1) * POSITION_GAP,
  }));
}

/**
 * Reorder a deck's cards to match `orderedIds`.
 *
 * Restripes positions to clean integer gaps following the given order and
 * enqueues ONE coalesced `update` per card that actually moved (per invariant
 * #8: one entry per moved card). Skipping no-op writes avoids bumping
 * `client_updated_at` on untouched cards, which under last-write-wins
 * (ARCHITECTURE.md §4.3) could clobber a concurrent edit. Each moved card is
 * written optimistically to Dexie too, so the live card list reflects the new
 * order immediately.
 *
 * `currentPositions` maps each card id to its position before the reorder so
 * unmoved cards can be skipped. Ids absent from the map are always written.
 */
export async function reorderCards(
  _deckId: string,
  orderedIds: string[],
  currentPositions?: ReadonlyMap<string, number> | Record<string, number>,
): Promise<void> {
  const positionOf = (id: string): number | undefined => {
    if (currentPositions === undefined) return undefined;
    if (currentPositions instanceof Map) return currentPositions.get(id);
    return (currentPositions as Record<string, number>)[id];
  };
  const updates = computeReorderedPositions(orderedIds);
  const stamp = nowIso();
  for (const { id, position } of updates) {
    // Skip cards whose computed position equals their current position: a
    // reorder must not re-stamp client_updated_at on cards it did not move.
    if (positionOf(id) === position) {
      continue;
    }
    const existing = await db.cards.get(id);
    if (existing) {
      await db.cards.put({ ...existing, position, client_updated_at: stamp });
    }
    await enqueueCoalesced(db, {
      type: "update",
      entity: "cards",
      recordId: id,
      payload: { position, client_updated_at: stamp },
    });
  }
  wakeSync();
}
