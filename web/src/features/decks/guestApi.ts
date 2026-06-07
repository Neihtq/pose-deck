/**
 * Data-access primitives for `deck_guests` (M5 sharing, ARCHITECTURE.md §3.5/§6).
 *
 * Sharing is grant/revoke only — NO share links, NO QR. An owner grants a guest
 * read access to a deck by the guest's exact email; the guest then sees the
 * deck (read-only) in their list. Like `card_images`, `deck_guests` has no LWW
 * clock — a grant is an insert and a revoke is a hard delete (the payload
 * carries no `client_updated_at`).
 *
 * As of M3 these are local-first: a grant writes the optimistic row into Dexie
 * immediately and enqueues a coalesced `create` outbox entry (drained by the
 * sync engine); a revoke hard-deletes the local row and enqueues a `delete`.
 * Reads come from Dexie live queries (`liveDeckGuests`).
 *
 * Resolving a guest by email (verified against live PocketBase): the owner
 * calls the `users` list endpoint passing ONLY the `email` QUERY PARAM. The
 * matched user's `email` (and other fields) are hidden by the collection's
 * viewRule, so a client-side `filter='email="..."'` would EXCLUDE the matched
 * row (its email reads back empty) and return nothing. The relaxed listRule
 * (migration 1700000008) returns the caller's own row PLUS the row whose email
 * matches the query param; we resolve by taking the row whose id is not the
 * caller's. An absent `email` param returns only the caller (enumeration is
 * blocked), so a non-existent email resolves to `null`.
 */
import { db } from "@/lib/db";
import { newClientId } from "@/lib/ids";
import { markRecentlyCreated } from "@/lib/localStore";
import { enqueueCoalesced } from "@/lib/outbox";
import { pb } from "@/lib/pocketbase";
import { wakeSync } from "@/sync";
import type { DeckGuest, ISODateString } from "@/lib/types";

/** Current wall-clock time as an ISO 8601 string. */
function nowIso(): ISODateString {
  return new Date().toISOString();
}

/**
 * The authenticated user's id (the owner issuing the grant). Throws when signed
 * out, mirroring deckApi's `currentUserId`.
 */
function currentUserId(): string {
  const id = pb.authStore.record?.id;
  if (typeof id !== "string" || id === "") {
    throw new Error("Cannot share a deck while signed out.");
  }
  return id;
}

/**
 * Resolve a user id by exact email, or `null` if no such user exists.
 *
 * Passes ONLY the `email` query param (NO client-side filter — see module
 * docstring). The endpoint returns the caller's own row plus the matched row;
 * we pick the row whose id is not the caller's. No match → only the caller's
 * row is returned → `null`.
 */
export async function resolveUserByEmail(
  email: string,
): Promise<string | null> {
  const me = currentUserId();
  const rows = await pb
    .collection("users")
    .getFullList({ query: { email } });
  return rows.find((r) => r.id !== me)?.id ?? null;
}

/**
 * Grant `email`'s user read access to `deckId`.
 *
 * Resolves the email → user id (throws a typed error if no such user), mints a
 * client id, writes the optimistic `deck_guests` row to Dexie, marks it
 * recently-created so a racing hydrate can't prune it (FIX #8), enqueues a
 * coalesced `create` (no `client_updated_at` — guests have no LWW clock), and
 * wakes the sync engine. Returns the optimistic guest row.
 *
 * A re-grant of an already-shared (deck,user) pair is idempotent: the server's
 * composite-unique 400 is classified as success by `serverEntities.send`
 * (FIX #6), so the optimistic row is kept.
 */
export class GuestNotFoundError extends Error {
  constructor(public readonly email: string) {
    super(`No user with email ${email}`);
    this.name = "GuestNotFoundError";
  }
}

export async function grantGuest(
  deckId: string,
  email: string,
): Promise<DeckGuest> {
  const userId = await resolveUserByEmail(email);
  if (userId === null) {
    throw new GuestNotFoundError(email);
  }
  const stamp = nowIso();
  const guest: DeckGuest = {
    id: newClientId(),
    deck: deckId,
    user: userId,
    granted_at: stamp,
  };
  await db.deck_guests.put(guest);
  // Protect this optimistic row from a racing hydrate whose server snapshot
  // predates the grant's commit (FIX #8 — same race as a deck/card create).
  markRecentlyCreated("deck_guests", guest.id);
  await enqueueCoalesced(db, {
    type: "create",
    entity: "deck_guests",
    recordId: guest.id,
    // No `client_updated_at`: deck_guests are insert / hard-delete, no LWW.
    payload: { deck: deckId, user: userId, granted_at: stamp },
  });
  wakeSync();
  return guest;
}

/**
 * Revoke a guest grant by its id: hard-delete the local row and enqueue a
 * coalesced `delete`. A grant-then-revoke before the create flushes coalesces
 * to a no-op (the pending create is cancelled), so no orphan reaches the server.
 */
export async function revokeGuest(guestId: string): Promise<void> {
  await db.deck_guests.delete(guestId);
  await enqueueCoalesced(db, {
    type: "delete",
    entity: "deck_guests",
    recordId: guestId,
    payload: {},
  });
  wakeSync();
}
