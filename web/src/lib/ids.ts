/**
 * Client-side id + idempotency-key minting for the offline-first sync layer
 * (M3, ARCHITECTURE.md §4.2).
 *
 * The sync design uses **client-supplied record ids** on create. PocketBase
 * accepts a caller-provided 15-character alphanumeric `id` on POST and returns
 * it unchanged (verified against the live backend). This makes create
 * idempotent: a retry after a lost 2xx hits the existing id and PocketBase
 * replies `400` with a `data.id` validation error, which the sync engine
 * classifies as success. It also means a record's local id equals its server
 * id from the moment it is created — so there is no temp-id → server-id
 * reconciliation, and child records can reference a parent's id immediately.
 */

/** Length of a PocketBase record id. */
export const PB_ID_LENGTH = 15;

/**
 * Alphabet PocketBase uses for generated ids (lowercase alphanumeric). We mint
 * from the same set so a client id is indistinguishable from a server one.
 */
const PB_ID_ALPHABET = "abcdefghijklmnopqrstuvwxyz0123456789";

/** Cryptographically-random integers in `[0, max)` without modulo bias. */
function randomInts(count: number, max: number): number[] {
  // Rejection-sample from a Uint32 source so the distribution over `max`
  // is uniform (no modulo bias toward low values).
  const out: number[] = [];
  const limit = Math.floor(0x1_0000_0000 / max) * max;
  const buf = new Uint32Array(count);
  while (out.length < count) {
    crypto.getRandomValues(buf);
    for (let i = 0; i < buf.length && out.length < count; i++) {
      const v = buf[i];
      if (v < limit) out.push(v % max);
    }
  }
  return out;
}

/**
 * Mint a new PocketBase-shaped record id: 15 lowercase-alphanumeric chars.
 *
 * Used as the `id` on create so the record's identity is stable across the
 * optimistic local write and the eventual server insert.
 */
export function newClientId(): string {
  const idx = randomInts(PB_ID_LENGTH, PB_ID_ALPHABET.length);
  let id = "";
  for (const i of idx) id += PB_ID_ALPHABET[i];
  return id;
}

/** Mint a UUID idempotency key for an outbox entry. */
export function newIdempotencyKey(): string {
  return crypto.randomUUID();
}

/**
 * Whether `value` has the shape of a PocketBase record id (15 chars from the
 * id alphabet). A guard for assertions/tests — not a server-side existence
 * check.
 */
export function isClientId(value: unknown): value is string {
  return (
    typeof value === "string" &&
    value.length === PB_ID_LENGTH &&
    [...value].every((c) => PB_ID_ALPHABET.includes(c))
  );
}
