import { ClientResponseError } from "pocketbase";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { PoseDeckDB } from "../db";
import { enqueue, pending } from "../outbox";
import type { MutationTransport } from "../serverEntities";
import { SyncEngine } from "../syncEngine";

function freshDb(): PoseDeckDB {
  return new PoseDeckDB(`test-${crypto.randomUUID()}`);
}

function okTransport(over: Partial<MutationTransport> = {}): MutationTransport {
  return {
    create: vi.fn(async (_e, body) => ({ ...body, created: "c", updated: "u" })),
    update: vi.fn(async (_e, id) => ({ id, updated: "u" })),
    delete: vi.fn(async () => undefined),
    ...over,
  };
}

function pbError(status: number, data: Record<string, unknown> = {}): ClientResponseError {
  return new ClientResponseError({ status, response: { data } });
}

describe("SyncEngine.drain", () => {
  let db: PoseDeckDB;
  beforeEach(async () => {
    db = freshDb();
    await db.open();
  });

  it("drains all entries in FIFO order on success and reconciles", async () => {
    await enqueue(db, { type: "create", entity: "decks", recordId: "d1", payload: { name: "A" } });
    await enqueue(db, { type: "create", entity: "decks", recordId: "d2", payload: { name: "B" } });
    const seen: string[] = [];
    const transport = okTransport({
      create: vi.fn(async (_e, body) => {
        seen.push(String((body as { id: string }).id));
        return { ...body, created: "c", updated: "u" };
      }),
    });
    const reconcile = vi.fn();
    const engine = new SyncEngine({ db, transport, hooks: { reconcile }, pollMs: 0 });

    await engine.drain();

    expect(seen).toEqual(["d1", "d2"]);
    expect(await pending(db)).toHaveLength(0);
    expect(reconcile).toHaveBeenCalledTimes(2);
  });

  it("drops a 4xx entry, rolls back, surfaces error, and keeps draining", async () => {
    await enqueue(db, { type: "update", entity: "cards", recordId: "c1", payload: { title: "" } });
    await enqueue(db, { type: "update", entity: "cards", recordId: "c2", payload: { title: "ok" } });
    let calls = 0;
    const transport = okTransport({
      update: vi.fn(async (_e, id) => {
        calls++;
        if (id === "c1") throw pbError(400, { title: { code: "required" } });
        return { id, updated: "u" };
      }),
    });
    const rollback = vi.fn();
    const onError = vi.fn();
    const engine = new SyncEngine({ db, transport, hooks: { rollback, onError }, pollMs: 0 });

    await engine.drain();

    expect(calls).toBe(2); // both attempted; c1 dropped, c2 succeeded
    expect(rollback).toHaveBeenCalledTimes(1);
    expect(onError).toHaveBeenCalledTimes(1);
    expect(await pending(db)).toHaveLength(0);
  });

  it("backs off a 5xx at the head of line and preserves the queue", async () => {
    await enqueue(db, { type: "update", entity: "cards", recordId: "c1", payload: {} });
    await enqueue(db, { type: "update", entity: "cards", recordId: "c2", payload: {} });
    const transport = okTransport({
      update: vi.fn(async () => {
        throw pbError(503);
      }),
    });
    let clock = 1000;
    const engine = new SyncEngine({
      db,
      transport,
      pollMs: 0,
      now: () => clock,
      backoff: { baseMs: 1000, maxMs: 60_000 },
    });

    await engine.drain();

    // Head entry backed off; both still queued (head-of-line preserved).
    const rows = await pending(db);
    expect(rows).toHaveLength(2);
    const head = rows[0];
    expect(head.retry_count).toBe(1);
    expect(head.next_attempt_at).toBe(clock + 1000);
    expect(head.status).toBe("pending");

    // Before backoff elapses, draining is a no-op (head not eligible).
    await engine.drain();
    expect((await pending(db))[0].retry_count).toBe(1);

    // After backoff, it retries (and fails again → retry_count 2).
    clock = 5000;
    await engine.drain();
    expect((await pending(db))[0].retry_count).toBe(2);
  });

  it("pauses on 401 and resumes after re-auth", async () => {
    await enqueue(db, { type: "update", entity: "cards", recordId: "c1", payload: {} });
    let authed = false;
    const transport = okTransport({
      update: vi.fn(async (_e, id) => {
        if (!authed) throw pbError(401);
        return { id, updated: "u" };
      }),
    });
    const engine = new SyncEngine({ db, transport, pollMs: 0 });

    await engine.drain();
    expect(engine.state).toBe("paused");
    expect(await pending(db)).toHaveLength(1); // not dropped

    authed = true;
    engine.resume();
    await engine.drain();
    expect(await pending(db)).toHaveLength(0);
  });

  it("drops an entry after exceeding maxRetries", async () => {
    await enqueue(db, { type: "update", entity: "cards", recordId: "c1", payload: {} });
    const transport = okTransport({
      update: vi.fn(async () => {
        throw pbError(500);
      }),
    });
    const onError = vi.fn();
    let clock = 0;
    const engine = new SyncEngine({
      db,
      transport,
      hooks: { onError },
      pollMs: 0,
      maxRetries: 3,
      backoff: { baseMs: 1, maxMs: 1 },
      now: () => clock,
    });

    // Each drain attempts the head once then backs off; advance the clock past
    // the (tiny) backoff between passes.
    for (let i = 0; i < 5; i++) {
      await engine.drain();
      clock += 10;
    }
    expect(await pending(db)).toHaveLength(0);
    expect(onError).toHaveBeenCalledWith(expect.anything(), expect.stringContaining("max retries"));
  });

  it("is single-flight: concurrent drains do not double-send", async () => {
    await enqueue(db, { type: "create", entity: "decks", recordId: "d1", payload: {} });
    let inFlight = 0;
    let maxConcurrent = 0;
    const transport = okTransport({
      create: vi.fn(async (_e, body) => {
        inFlight++;
        maxConcurrent = Math.max(maxConcurrent, inFlight);
        await new Promise((r) => setTimeout(r, 5));
        inFlight--;
        return { ...body, created: "c", updated: "u" };
      }),
    });
    const engine = new SyncEngine({ db, transport, pollMs: 0 });

    await Promise.all([engine.drain(), engine.drain(), engine.drain()]);

    expect(maxConcurrent).toBe(1);
    expect(transport.create).toHaveBeenCalledTimes(1);
  });
});
