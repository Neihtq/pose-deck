/**
 * Outbox queue primitives (M3 sync, ARCHITECTURE.md §4.2).
 *
 * The outbox is a Dexie-backed FIFO queue of pending mutations. Mutations are
 * enqueued by the data-access layer immediately after the optimistic local
 * write, and drained in order by the sync engine (`syncEngine.ts`). This module
 * owns only the *queue mechanics* — enqueue, ordered peek, delete, retry
 * backoff bump, and coalescing of redundant mutations for the same record. It
 * does no network I/O.
 *
 * Ordering: entries are processed by ascending auto-increment `id`, which is
 * monotonic with enqueue order (and therefore with `local_timestamp`). We rely
 * on `id` rather than the timestamp string so two mutations in the same
 * millisecond keep a stable FIFO order.
 */
import type { PoseDeckDB } from "./db";
import type { OutboxEntity, OutboxEntry, OutboxOperation } from "./db";
import { newIdempotencyKey } from "./ids";

/** Input for enqueuing a new mutation (queue bookkeeping fields are filled in). */
export interface EnqueueInput {
  type: OutboxOperation;
  entity: OutboxEntity;
  recordId: string;
  /** Mutation payload; serialized to JSON for storage. */
  payload: unknown;
}

/** Serialize a payload object to the stored JSON string form. */
export function encodeOutboxPayload(payload: unknown): string {
  return JSON.stringify(payload ?? {});
}

/** Parse a stored outbox payload string back into an object. */
export function decodeOutboxPayload<T = Record<string, unknown>>(
  entry: Pick<OutboxEntry, "payload">,
): T {
  return JSON.parse(entry.payload) as T;
}

/**
 * Append a mutation to the outbox.
 *
 * Returns the created entry's auto-increment id. The entry starts `pending`
 * with `next_attempt_at = 0` so the drain loop picks it up immediately.
 */
export async function enqueue(
  db: PoseDeckDB,
  input: EnqueueInput,
  now: () => Date = () => new Date(),
): Promise<number> {
  const entry: OutboxEntry = {
    type: input.type,
    entity: input.entity,
    recordId: input.recordId,
    payload: encodeOutboxPayload(input.payload),
    idempotency_key: newIdempotencyKey(),
    local_timestamp: now().toISOString(),
    retry_count: 0,
    status: "pending",
    next_attempt_at: 0,
  };
  return (await db.outbox.add(entry)) as number;
}

/**
 * The next entry eligible to send, or `undefined` if none.
 *
 * Eligible = lowest `id` among entries that are not `inflight` and whose
 * `next_attempt_at` has passed. Honors FIFO by `id`.
 */
export async function peekFifo(
  db: PoseDeckDB,
  now: () => number = () => Date.now(),
): Promise<OutboxEntry | undefined> {
  const nowMs = now();
  // Scan in id order and return the first eligible entry. The queue is small
  // (pending user mutations), so an ordered scan is cheaper than maintaining a
  // compound index, and it keeps strict head-of-line FIFO semantics.
  const ordered = await db.outbox.orderBy("id").toArray();
  return ordered.find(
    (e) =>
      e.status !== "inflight" && (e.next_attempt_at ?? 0) <= nowMs,
  );
}

/** All pending entries in FIFO order (oldest id first). */
export async function pending(db: PoseDeckDB): Promise<OutboxEntry[]> {
  return db.outbox.orderBy("id").toArray();
}

/** Mark an entry in-flight (single-flight guard during a send). */
export async function markInflight(
  db: PoseDeckDB,
  id: number,
): Promise<void> {
  await db.outbox.update(id, { status: "inflight" });
}

/** Return an in-flight entry to `pending` (e.g. after a transient failure). */
export async function markPending(db: PoseDeckDB, id: number): Promise<void> {
  await db.outbox.update(id, { status: "pending" });
}

/** Remove an entry once its mutation is confirmed by the server. */
export async function deleteEntry(db: PoseDeckDB, id: number): Promise<void> {
  await db.outbox.delete(id);
}

/**
 * Record a failed attempt: bump `retry_count`, store the error, set the
 * `next_attempt_at` backoff, and return the entry to `pending`.
 *
 * Exponential backoff with a cap: `base * 2^retry_count`, capped at `maxMs`.
 * The new `retry_count` is returned so callers can enforce a max-attempts drop.
 */
export interface BackoffOptions {
  baseMs?: number;
  maxMs?: number;
}

export async function bumpRetry(
  db: PoseDeckDB,
  entry: OutboxEntry,
  error: string,
  opts: BackoffOptions = {},
  now: () => number = () => Date.now(),
): Promise<number> {
  const baseMs = opts.baseMs ?? 1000;
  const maxMs = opts.maxMs ?? 60_000;
  const nextRetry = entry.retry_count + 1;
  const delay = Math.min(maxMs, baseMs * 2 ** entry.retry_count);
  await db.outbox.update(entry.id as number, {
    retry_count: nextRetry,
    last_error: error,
    status: "pending",
    next_attempt_at: now() + delay,
  });
  return nextRetry;
}

/**
 * Coalesce a new mutation against the queue's existing *pending* entries for
 * the same record, reducing redundant network round-trips. Returns the action
 * taken so the caller can keep its in-memory view consistent.
 *
 * Rules (only entries with `status === "pending"` are eligible — an `inflight`
 * entry is mid-send and must not be mutated):
 *  - existing `create` + new `update` → keep the create, merge payload fields
 *    into it (the record does not exist server-side yet, so the create must
 *    carry the latest field values). One create is sent.
 *  - existing `create` + new `delete` → cancel both (record never reached the
 *    server, so nothing to delete). The create entry is removed; no delete is
 *    enqueued.
 *  - existing `update` + new `update` → replace the older update's payload with
 *    the merged latest values (last write wins locally). One update is sent.
 *  - existing `update` + new `delete` → drop the pending update(s) and enqueue
 *    the delete (deleting supersedes a field edit).
 *  - otherwise (no coalescible pending entry) → enqueue normally.
 *
 * `db` operations run inside the caller's transaction when invoked within one.
 */
export type CoalesceResult =
  | { action: "enqueued"; id: number }
  | { action: "merged-into-create"; id: number }
  | { action: "merged-into-update"; id: number }
  | { action: "canceled-create" }
  | { action: "superseded-by-delete"; id: number };

export async function enqueueCoalesced(
  db: PoseDeckDB,
  input: EnqueueInput,
  now: () => Date = () => new Date(),
): Promise<CoalesceResult> {
  const existing = (
    await db.outbox.where("recordId").equals(input.recordId).toArray()
  )
    .filter((e) => e.entity === input.entity && e.status !== "inflight")
    .sort((a, b) => (a.id as number) - (b.id as number));

  const pendingCreate = existing.find((e) => e.type === "create");
  const pendingUpdates = existing.filter((e) => e.type === "update");

  if (input.type === "update") {
    if (pendingCreate) {
      const merged = {
        ...decodeOutboxPayload(pendingCreate),
        ...(input.payload as Record<string, unknown>),
      };
      await db.outbox.update(pendingCreate.id as number, {
        payload: encodeOutboxPayload(merged),
      });
      return { action: "merged-into-create", id: pendingCreate.id as number };
    }
    if (pendingUpdates.length > 0) {
      // Fold all pending updates into the earliest one and drop the rest, so
      // exactly one PATCH carries the latest field values.
      const target = pendingUpdates[0];
      let merged: Record<string, unknown> = {};
      for (const u of pendingUpdates) {
        merged = { ...merged, ...decodeOutboxPayload(u) };
      }
      merged = { ...merged, ...(input.payload as Record<string, unknown>) };
      await db.outbox.update(target.id as number, {
        payload: encodeOutboxPayload(merged),
      });
      for (const u of pendingUpdates.slice(1)) {
        await db.outbox.delete(u.id as number);
      }
      return { action: "merged-into-update", id: target.id as number };
    }
  }

  if (input.type === "delete") {
    if (pendingCreate) {
      // The record never reached the server: cancel the create and any pending
      // updates; nothing to delete remotely.
      await db.outbox.delete(pendingCreate.id as number);
      for (const u of pendingUpdates) {
        await db.outbox.delete(u.id as number);
      }
      return { action: "canceled-create" };
    }
    if (pendingUpdates.length > 0) {
      // Delete supersedes pending field edits: drop them, enqueue the delete.
      for (const u of pendingUpdates) {
        await db.outbox.delete(u.id as number);
      }
      const id = await enqueue(db, input, now);
      return { action: "superseded-by-delete", id };
    }
  }

  const id = await enqueue(db, input, now);
  return { action: "enqueued", id };
}

/** Re-export so callers can mint keys without importing two modules. */
export { newIdempotencyKey };
