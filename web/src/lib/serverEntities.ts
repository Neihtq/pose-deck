/**
 * Maps outbox entries to PocketBase network calls and classifies the result
 * (M3 sync, ARCHITECTURE.md §4.2).
 *
 * Responsibilities:
 *  - `send(entry)` — dispatch one queued mutation to the right collection with
 *    a stable `requestKey` (so the SDK's default auto-cancellation does not
 *    abort our sequential FIFO sends), using the client-supplied id on create.
 *  - classify the outcome: `success` (incl. the idempotent "id already exists"
 *    400 after a lost ack), `drop` (a genuine 4xx the user can't retry past),
 *    `auth` (401 — pause until re-auth), or `retry` (429/5xx/network/offline).
 *  - `reconcile` — merge server-canonical timestamps into the local row on 2xx.
 *  - `rollback` — best-effort local revert when a mutation is dropped on 4xx.
 *
 * Per-entity payload rules (the data model is LOCKED — types.ts):
 *  - `decks`, `cards` carry `client_updated_at` (+ `deleted_at` for soft-delete).
 *  - `card_completions` carry `changed_at` (no `client_updated_at`).
 *  - `card_images` are create + hard-delete only — no update, no LWW field.
 *  - `deck_guests` are create + hard-delete only (grant / revoke).
 */
import { ClientResponseError } from "pocketbase";

import type { OutboxEntity, OutboxEntry } from "./db";
import { decodeOutboxPayload } from "./outbox";
import { collections } from "./pocketbase";

/** Outcome classification for one send attempt. */
export type SendOutcome =
  | { kind: "success"; record?: unknown }
  | { kind: "drop"; reason: string }
  | { kind: "auth"; reason: string }
  | { kind: "retry"; reason: string };

/**
 * A minimal record-service surface, so tests can inject a fake instead of a
 * live PocketBase. Mirrors the subset of the SDK's `RecordService` we use.
 */
export interface MutationTransport {
  create(
    entity: OutboxEntity,
    body: Record<string, unknown>,
    options: { requestKey: string },
  ): Promise<Record<string, unknown>>;
  update(
    entity: OutboxEntity,
    id: string,
    body: Record<string, unknown>,
    options: { requestKey: string },
  ): Promise<Record<string, unknown>>;
  delete(
    entity: OutboxEntity,
    id: string,
    options: { requestKey: string },
  ): Promise<void>;
}

/**
 * The production transport over the shared PocketBase client. `requestKey` is
 * forwarded so concurrent/sequential requests to the same collection are NOT
 * auto-cancelled by the SDK (its default dedup key is METHOD+URL, which would
 * abort our back-to-back FIFO updates to the same collection).
 */
export const pocketBaseTransport: MutationTransport = {
  create: (entity, body, options) =>
    collections[entity]().create(body, options) as Promise<
      Record<string, unknown>
    >,
  update: (entity, id, body, options) =>
    collections[entity]().update(id, body, options) as Promise<
      Record<string, unknown>
    >,
  delete: (entity, id, options) =>
    collections[entity]().delete(id, options).then(() => undefined),
};

/**
 * Does a 400 response indicate a duplicate id (our own create replayed after a
 * lost ack)? PocketBase returns `400` with a validation error on `data.id`
 * when the supplied id already exists. We treat that as success — the record
 * is on the server; the local store already has it.
 */
function isDuplicateIdError(err: ClientResponseError): boolean {
  if (err.status !== 400) return false;
  const data = (err.response as { data?: Record<string, unknown> })?.data;
  return Boolean(data && "id" in data);
}

/** Classify a thrown error from a send attempt. */
function classifyError(err: unknown): SendOutcome {
  if (err instanceof ClientResponseError) {
    // The SDK aborts in-flight requests on auto-cancel; treat as a transient
    // retry that should NOT count as a real failure attempt.
    if (err.isAbort) return { kind: "retry", reason: "aborted" };
    if (err.status === 0) return { kind: "retry", reason: "network/offline" };
    if (err.status === 401) return { kind: "auth", reason: "unauthorized" };
    if (err.status === 429) return { kind: "retry", reason: "rate-limited" };
    if (err.status >= 500) return { kind: "retry", reason: `server ${err.status}` };
    if (err.status >= 400) return { kind: "drop", reason: `client ${err.status}` };
  }
  // Unknown / non-HTTP errors (e.g. fetch TypeError offline) → retry.
  return { kind: "retry", reason: String((err as Error)?.message ?? err) };
}

/**
 * Send one outbox entry. The `recordId` is the client-supplied id, so a create
 * carries `id` in its body and a retry after a lost 2xx is idempotent.
 */
export async function send(
  entry: OutboxEntry,
  transport: MutationTransport = pocketBaseTransport,
): Promise<SendOutcome> {
  const body = decodeOutboxPayload(entry);
  const options = { requestKey: entry.idempotency_key };
  try {
    switch (entry.type) {
      case "create": {
        const record = await transport.create(
          entry.entity,
          { ...body, id: entry.recordId },
          options,
        );
        return { kind: "success", record };
      }
      case "update": {
        const record = await transport.update(
          entry.entity,
          entry.recordId,
          body,
          options,
        );
        return { kind: "success", record };
      }
      case "delete": {
        await transport.delete(entry.entity, entry.recordId, options);
        return { kind: "success" };
      }
    }
  } catch (err) {
    if (
      entry.type === "create" &&
      err instanceof ClientResponseError &&
      isDuplicateIdError(err)
    ) {
      // Idempotent replay: the record already exists from a prior attempt whose
      // ack we lost. The optimistic local row is already correct.
      return { kind: "success" };
    }
    return classifyError(err);
  }
  // Unreachable, but satisfies the type checker.
  return { kind: "retry", reason: "unhandled" };
}

/**
 * Which timestamp field a collection orders by for last-write-wins, or
 * `undefined` for collections that don't use LWW (images, guests — insert /
 * hard-delete only). Shared by the merge logic in `localStore`/realtime.
 */
export function lwwKey(entity: OutboxEntity): string | undefined {
  switch (entity) {
    case "decks":
    case "cards":
      return "client_updated_at";
    case "card_completions":
      return "changed_at";
    default:
      return undefined; // card_images, deck_guests
  }
}
