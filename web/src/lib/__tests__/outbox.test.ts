import { beforeEach, describe, expect, it } from "vitest";

import { PoseDeckDB } from "../db";
import {
  bumpRetry,
  decodeOutboxPayload,
  enqueue,
  enqueueCoalesced,
  markInflight,
  peekFifo,
  pending,
  requeueInflight,
} from "../outbox";

function freshDb(): PoseDeckDB {
  return new PoseDeckDB(`test-${crypto.randomUUID()}`);
}

describe("outbox enqueue + FIFO", () => {
  let db: PoseDeckDB;
  beforeEach(async () => {
    db = freshDb();
    await db.open();
  });

  it("enqueues with bookkeeping defaults and reads back in id order", async () => {
    const a = await enqueue(db, {
      type: "create",
      entity: "decks",
      recordId: "d1",
      payload: { name: "A" },
    });
    const b = await enqueue(db, {
      type: "create",
      entity: "decks",
      recordId: "d2",
      payload: { name: "B" },
    });
    expect(b).toBeGreaterThan(a);

    const all = await pending(db);
    expect(all.map((e) => e.recordId)).toEqual(["d1", "d2"]);
    expect(all[0].status).toBe("pending");
    expect(all[0].retry_count).toBe(0);
    expect(all[0].idempotency_key).toMatch(/[0-9a-f-]{36}/i);
    expect(decodeOutboxPayload(all[0])).toEqual({ name: "A" });
  });

  it("peekFifo returns the oldest eligible entry and skips inflight ones", async () => {
    await enqueue(db, { type: "create", entity: "decks", recordId: "d1", payload: {} });
    await enqueue(db, { type: "create", entity: "decks", recordId: "d2", payload: {} });

    const first = await peekFifo(db);
    expect(first?.recordId).toBe("d1");

    await markInflight(db, first!.id as number);
    const next = await peekFifo(db);
    expect(next?.recordId).toBe("d2");
  });

  it("peekFifo honors next_attempt_at backoff", async () => {
    const id = await enqueue(db, {
      type: "create",
      entity: "decks",
      recordId: "d1",
      payload: {},
    });
    // Push its next attempt into the future.
    await db.outbox.update(id, { next_attempt_at: 10_000 });
    expect(await peekFifo(db, () => 5_000)).toBeUndefined();
    expect((await peekFifo(db, () => 20_000))?.recordId).toBe("d1");
  });
});

describe("requeueInflight (stale-inflight recovery)", () => {
  let db: PoseDeckDB;
  beforeEach(async () => {
    db = freshDb();
    await db.open();
  });

  it("resets rows orphaned inflight by a dead runtime back to pending so they re-send", async () => {
    // Simulate a crash mid-send: an entry left `inflight`, plus a later pending
    // entry behind it.
    const stuck = await enqueue(db, {
      type: "create",
      entity: "decks",
      recordId: "d1",
      payload: {},
    });
    await enqueue(db, { type: "create", entity: "decks", recordId: "d2", payload: {} });
    await markInflight(db, stuck);

    // Before recovery, the orphan is skipped by FIFO peek (never re-attempted).
    expect((await peekFifo(db))?.recordId).toBe("d2");
    expect((await db.outbox.get(stuck))!.status).toBe("inflight");

    const reset = await requeueInflight(db);
    expect(reset).toBe(1);

    // After recovery the orphan is pending again and is the FIFO head once more.
    expect((await db.outbox.get(stuck))!.status).toBe("pending");
    expect((await peekFifo(db))?.recordId).toBe("d1");
  });

  it("is a no-op when nothing is inflight", async () => {
    await enqueue(db, { type: "create", entity: "decks", recordId: "d1", payload: {} });
    expect(await requeueInflight(db)).toBe(0);
    expect((await pending(db))[0].status).toBe("pending");
  });
});

describe("bumpRetry backoff", () => {
  let db: PoseDeckDB;
  beforeEach(async () => {
    db = freshDb();
    await db.open();
  });

  it("increments retry_count and schedules exponential backoff capped at maxMs", async () => {
    const id = await enqueue(db, {
      type: "update",
      entity: "cards",
      recordId: "c1",
      payload: {},
    });
    let entry = (await db.outbox.get(id))!;

    const n1 = await bumpRetry(db, entry, "boom", { baseMs: 1000, maxMs: 60_000 }, () => 0);
    expect(n1).toBe(1);
    entry = (await db.outbox.get(id))!;
    expect(entry.retry_count).toBe(1);
    expect(entry.last_error).toBe("boom");
    expect(entry.next_attempt_at).toBe(1000); // base * 2^0

    const n2 = await bumpRetry(db, entry, "boom2", { baseMs: 1000, maxMs: 60_000 }, () => 0);
    expect(n2).toBe(2);
    entry = (await db.outbox.get(id))!;
    expect(entry.next_attempt_at).toBe(2000); // base * 2^1

    // Drive retry_count high and confirm the cap holds.
    await db.outbox.update(id, { retry_count: 20 });
    entry = (await db.outbox.get(id))!;
    await bumpRetry(db, entry, "boom", { baseMs: 1000, maxMs: 60_000 }, () => 0);
    entry = (await db.outbox.get(id))!;
    expect(entry.next_attempt_at).toBe(60_000); // capped
  });
});

describe("enqueueCoalesced", () => {
  let db: PoseDeckDB;
  beforeEach(async () => {
    db = freshDb();
    await db.open();
  });

  it("merges an update into a pending create (one create sent)", async () => {
    await enqueueCoalesced(db, {
      type: "create",
      entity: "cards",
      recordId: "c1",
      payload: { title: "A", notes: "" },
    });
    const res = await enqueueCoalesced(db, {
      type: "update",
      entity: "cards",
      recordId: "c1",
      payload: { title: "B" },
    });
    expect(res.action).toBe("merged-into-create");

    const all = await pending(db);
    expect(all).toHaveLength(1);
    expect(all[0].type).toBe("create");
    expect(decodeOutboxPayload(all[0])).toEqual({ title: "B", notes: "" });
  });

  it("cancels both when a delete follows a pending create", async () => {
    await enqueueCoalesced(db, {
      type: "create",
      entity: "cards",
      recordId: "c1",
      payload: { title: "A" },
    });
    await enqueueCoalesced(db, {
      type: "update",
      entity: "cards",
      recordId: "c1",
      payload: { title: "B" },
    });
    const res = await enqueueCoalesced(db, {
      type: "delete",
      entity: "cards",
      recordId: "c1",
      payload: { deleted_at: "2026-01-01T00:00:00Z" },
    });
    expect(res.action).toBe("canceled-create");
    expect(await pending(db)).toHaveLength(0);
  });

  it("folds multiple updates into one (last write wins locally)", async () => {
    await enqueueCoalesced(db, { type: "update", entity: "cards", recordId: "c1", payload: { title: "A" } });
    await enqueueCoalesced(db, { type: "update", entity: "cards", recordId: "c1", payload: { notes: "n" } });
    const res = await enqueueCoalesced(db, { type: "update", entity: "cards", recordId: "c1", payload: { title: "C" } });
    expect(res.action).toBe("merged-into-update");
    const all = await pending(db);
    expect(all).toHaveLength(1);
    expect(decodeOutboxPayload(all[0])).toEqual({ title: "C", notes: "n" });
  });

  it("delete supersedes pending updates (no pending create)", async () => {
    await enqueueCoalesced(db, { type: "update", entity: "cards", recordId: "c1", payload: { title: "A" } });
    const res = await enqueueCoalesced(db, {
      type: "delete",
      entity: "cards",
      recordId: "c1",
      payload: { deleted_at: "2026-01-01T00:00:00Z" },
    });
    expect(res.action).toBe("superseded-by-delete");
    const all = await pending(db);
    expect(all).toHaveLength(1);
    expect(all[0].type).toBe("delete");
  });

  it("does not coalesce into an inflight entry", async () => {
    const id = await enqueue(db, {
      type: "create",
      entity: "cards",
      recordId: "c1",
      payload: { title: "A" },
    });
    await markInflight(db, id);
    const res = await enqueueCoalesced(db, {
      type: "update",
      entity: "cards",
      recordId: "c1",
      payload: { title: "B" },
    });
    // The create is mid-send, so the update must be a new entry, not merged.
    expect(res.action).toBe("enqueued");
    expect(await pending(db)).toHaveLength(2);
  });

  it("scopes coalescing by entity (same recordId, different entity stays separate)", async () => {
    await enqueueCoalesced(db, { type: "create", entity: "cards", recordId: "x", payload: {} });
    const res = await enqueueCoalesced(db, { type: "update", entity: "decks", recordId: "x", payload: {} });
    expect(res.action).toBe("enqueued");
    expect(await pending(db)).toHaveLength(2);
  });
});
