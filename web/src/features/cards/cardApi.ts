/**
 * Data-access primitives for `cards`.
 *
 * Thin async wrappers around `collections.cards()`. Cards live in a flat,
 * ordered list within a deck; ordering uses integer-gap `position` values
 * (1000, 2000, …) so a single card can usually be re-placed by computing a
 * midpoint without restriping the whole deck (ARCHITECTURE.md §3.3).
 *
 * Conventions (see web CLAUDE.md):
 *  - Every mutation stamps `client_updated_at` with the current ISO time.
 *  - Soft delete = set `deleted_at`; never hard-delete from the UI.
 *  - List queries exclude soft-deleted cards.
 */
import { collections, pb } from "@/lib/pocketbase";
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

/** List a deck's non-soft-deleted cards, ordered by `position`. */
export async function listCards(deckId: string): Promise<Card[]> {
  return collections.cards().getFullList({
    filter: pb.filter("deck = {:deck} && deleted_at = ''", { deck: deckId }),
    sort: "position",
  });
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
 * Reads the deck's current cards to compute the next integer-gap position, then
 * creates the record. Optional fields default to `""` to match PocketBase's
 * empty-string representation.
 */
export async function createCard(
  deckId: string,
  fields: CardFields,
): Promise<Card> {
  const existing = await listCards(deckId);
  return collections.cards().create({
    deck: deckId,
    position: nextPosition(existing),
    title: fields.title,
    time_slot: fields.time_slot ?? "",
    subjects: fields.subjects ?? "",
    direction: fields.direction ?? "",
    notes: fields.notes ?? "",
    deleted_at: "",
    client_updated_at: nowIso(),
  });
}

/** Update editable fields on a card. Only provided keys are written. */
export async function updateCard(
  id: string,
  fields: Partial<CardFields>,
): Promise<Card> {
  const patch: Partial<Card> & { client_updated_at: ISODateString } = {
    client_updated_at: nowIso(),
  };
  if (fields.title !== undefined) patch.title = fields.title;
  if (fields.time_slot !== undefined) patch.time_slot = fields.time_slot;
  if (fields.subjects !== undefined) patch.subjects = fields.subjects;
  if (fields.direction !== undefined) patch.direction = fields.direction;
  if (fields.notes !== undefined) patch.notes = fields.notes;
  return collections.cards().update(id, patch);
}

/** Soft-delete a card. Never hard-deletes. */
export async function softDeleteCard(id: string): Promise<Card> {
  return collections.cards().update(id, {
    deleted_at: nowIso(),
    client_updated_at: nowIso(),
  });
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
 * Restripes positions to clean integer gaps (1000, 2000, …) following the
 * given order and persists only the cards whose position actually changes.
 * Skipping no-op writes avoids bumping `client_updated_at` on untouched cards,
 * which under the last-write-wins model (ARCHITECTURE.md §4.3) could otherwise
 * clobber the ordering metadata of a concurrent edit that should have won.
 *
 * `currentPositions` maps each card id to its position before the reorder so
 * unmoved cards can be skipped. Ids absent from the map are always written
 * (treated as having an unknown/changed position). `deckId` is accepted for a
 * future scoping/validation hook and to keep the call site self-documenting;
 * the ordering itself is fully described by `orderedIds`.
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
    await collections.cards().update(id, {
      position,
      client_updated_at: stamp,
    });
  }
}
