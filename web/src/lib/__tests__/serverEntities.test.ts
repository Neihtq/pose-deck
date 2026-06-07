import { ClientResponseError } from "pocketbase";
import { describe, expect, it, vi } from "vitest";

import type { OutboxEntry } from "../db";
import { encodeOutboxPayload } from "../outbox";
import { type MutationTransport, lwwKey, send } from "../serverEntities";

function entry(over: Partial<OutboxEntry> = {}): OutboxEntry {
  return {
    id: 1,
    type: "create",
    entity: "decks",
    recordId: "deck0000000000a",
    payload: encodeOutboxPayload({ name: "A", client_updated_at: "t" }),
    idempotency_key: "key-1",
    local_timestamp: "2026-06-07T00:00:00.000Z",
    retry_count: 0,
    status: "pending",
    next_attempt_at: 0,
    ...over,
  };
}

function fakeTransport(over: Partial<MutationTransport> = {}): MutationTransport {
  return {
    create: vi.fn(async () => ({ id: "deck0000000000a", created: "c", updated: "u" })),
    update: vi.fn(async () => ({ id: "deck0000000000a", updated: "u" })),
    delete: vi.fn(async () => undefined),
    ...over,
  };
}

function pbError(status: number, data: Record<string, unknown> = {}): ClientResponseError {
  return new ClientResponseError({ status, response: { data } });
}

describe("send dispatch", () => {
  it("creates with the client-supplied id and a stable requestKey", async () => {
    const t = fakeTransport();
    const res = await send(entry(), t);
    expect(res.kind).toBe("success");
    expect(t.create).toHaveBeenCalledWith(
      "decks",
      expect.objectContaining({ id: "deck0000000000a", name: "A" }),
      { requestKey: "key-1" },
    );
  });

  it("updates by id", async () => {
    const t = fakeTransport();
    await send(entry({ type: "update", payload: encodeOutboxPayload({ name: "B" }) }), t);
    expect(t.update).toHaveBeenCalledWith(
      "decks",
      "deck0000000000a",
      { name: "B" },
      { requestKey: "key-1" },
    );
  });

  it("deletes by id", async () => {
    const t = fakeTransport();
    const res = await send(entry({ type: "delete" }), t);
    expect(res.kind).toBe("success");
    expect(t.delete).toHaveBeenCalledWith("decks", "deck0000000000a", { requestKey: "key-1" });
  });
});

describe("send outcome classification", () => {
  it("treats a 400 duplicate-id on create as idempotent success", async () => {
    const t = fakeTransport({
      create: vi.fn(async () => {
        throw pbError(400, { id: { code: "validation_not_unique" } });
      }),
    });
    const res = await send(entry(), t);
    expect(res.kind).toBe("success");
  });

  // FIX #6: a `deck_guests` re-grant trips the composite-unique (deck,user)
  // index, returning a 400 keyed on the relation fields (NOT `data.id`). The
  // grant is idempotent — the share already exists — so it must classify as
  // success, not a hard drop (which would toast + roll back the optimistic row).
  it("treats a deck_guests composite-unique 400 on create as idempotent success", async () => {
    const t = fakeTransport({
      create: vi.fn(async () => {
        throw pbError(400, {
          user: { code: "validation_not_unique", message: "Value must be unique." },
        });
      }),
    });
    const res = await send(
      entry({ entity: "deck_guests", recordId: "guest000000000a" }),
      t,
    );
    expect(res.kind).toBe("success");
  });

  it("still drops a generic 400 on a NON-deck_guests create (no id field)", async () => {
    const t = fakeTransport({
      create: vi.fn(async () => {
        throw pbError(400, { name: { code: "validation_required" } });
      }),
    });
    const res = await send(entry({ entity: "decks" }), t);
    expect(res).toEqual({ kind: "drop", reason: "client 400" });
  });

  it("classifies a generic 400 (no id field) as drop", async () => {
    const t = fakeTransport({
      update: vi.fn(async () => {
        throw pbError(400, { title: { code: "validation_required" } });
      }),
    });
    const res = await send(entry({ type: "update" }), t);
    expect(res).toEqual({ kind: "drop", reason: "client 400" });
  });

  it("classifies 401 as auth", async () => {
    const t = fakeTransport({
      update: vi.fn(async () => {
        throw pbError(401);
      }),
    });
    expect((await send(entry({ type: "update" }), t)).kind).toBe("auth");
  });

  it("classifies 429 and 5xx and status-0 (offline) as retry", async () => {
    for (const status of [429, 500, 503, 0]) {
      const t = fakeTransport({
        update: vi.fn(async () => {
          throw pbError(status);
        }),
      });
      expect((await send(entry({ type: "update" }), t)).kind).toBe("retry");
    }
  });

  it("classifies an SDK auto-cancel abort as retry", async () => {
    const abort = new ClientResponseError({ isAbort: true });
    const t = fakeTransport({
      update: vi.fn(async () => {
        throw abort;
      }),
    });
    expect((await send(entry({ type: "update" }), t)).kind).toBe("retry");
  });
});

describe("lwwKey", () => {
  it("maps per-entity ordering keys", () => {
    expect(lwwKey("decks")).toBe("client_updated_at");
    expect(lwwKey("cards")).toBe("client_updated_at");
    expect(lwwKey("card_completions")).toBe("changed_at");
    expect(lwwKey("card_images")).toBeUndefined();
    expect(lwwKey("deck_guests")).toBeUndefined();
  });
});
