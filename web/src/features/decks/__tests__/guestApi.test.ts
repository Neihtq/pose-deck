/**
 * Unit tests for guestApi (M5 sharing).
 *
 * Covers resolveUserByEmail (corrected resolver: email QUERY PARAM only, pick
 * the non-self row), grantGuest (optimistic Dexie row + recently-created mark +
 * coalesced create with NO client_updated_at), revokeGuest (hard delete +
 * delete enqueue), and grant-then-revoke coalescing to a no-op.
 */
import { beforeEach, describe, expect, it, vi } from "vitest";

import { db } from "@/lib/db";
import { decodeOutboxPayload } from "@/lib/outbox";

vi.mock("@/sync", () => ({ wakeSync: vi.fn() }));

const getFullList = vi.fn();
vi.mock("@/lib/pocketbase", () => ({
  pb: {
    authStore: { record: { id: "owner1" } },
    collection: () => ({ getFullList }),
  },
}));

import {
  GuestNotFoundError,
  grantGuest,
  resolveUserByEmail,
  revokeGuest,
} from "@/features/decks/guestApi";
import { recentlyCreatedKeepIds, clearRecentlyCreated } from "@/lib/localStore";

beforeEach(async () => {
  getFullList.mockReset();
  clearRecentlyCreated();
  await Promise.all([db.deck_guests.clear(), db.outbox.clear()]);
});

describe("resolveUserByEmail", () => {
  it("passes ONLY the email query param (no client filter) and picks the non-self row", async () => {
    getFullList.mockResolvedValue([
      { id: "owner1", email: "" }, // self (email hidden by viewRule)
      { id: "guest9", email: "" }, // matched guest
    ]);
    const id = await resolveUserByEmail("guest@posedeck.test");
    expect(id).toBe("guest9");
    expect(getFullList).toHaveBeenCalledWith({
      query: { email: "guest@posedeck.test" },
    });
    // No `filter` key — a client-side email filter would exclude the matched row.
    const arg = getFullList.mock.calls[0][0];
    expect(arg).not.toHaveProperty("filter");
  });

  it("returns null when only the caller's own row comes back (no such user)", async () => {
    getFullList.mockResolvedValue([{ id: "owner1", email: "" }]);
    expect(await resolveUserByEmail("nobody@nowhere.test")).toBeNull();
  });
});

describe("grantGuest", () => {
  it("writes an optimistic row, marks recently-created, and enqueues a create with no LWW clock", async () => {
    getFullList.mockResolvedValue([{ id: "owner1" }, { id: "guest9" }]);
    const guest = await grantGuest("deck1", "guest@posedeck.test");

    expect(guest.deck).toBe("deck1");
    expect(guest.user).toBe("guest9");
    expect(guest.granted_at).not.toBe("");
    expect(guest.id).toHaveLength(15);

    // Optimistic Dexie row present.
    expect((await db.deck_guests.get(guest.id))?.user).toBe("guest9");
    // Recently-created mark (FIX #8) exempts it from a racing prune.
    expect(recentlyCreatedKeepIds("deck_guests").has(guest.id)).toBe(true);

    // One create enqueued; payload carries deck/user/granted_at, NO client_updated_at.
    const queued = await db.outbox.toArray();
    expect(queued).toHaveLength(1);
    expect(queued[0].type).toBe("create");
    expect(queued[0].entity).toBe("deck_guests");
    const payload = decodeOutboxPayload(queued[0]);
    expect(payload).toEqual({
      deck: "deck1",
      user: "guest9",
      granted_at: guest.granted_at,
    });
    expect(payload).not.toHaveProperty("client_updated_at");
  });

  it("throws GuestNotFoundError when the email resolves to no user", async () => {
    getFullList.mockResolvedValue([{ id: "owner1" }]); // only self
    await expect(grantGuest("deck1", "ghost@nowhere.test")).rejects.toBeInstanceOf(
      GuestNotFoundError,
    );
    // No optimistic row or queue entry written on a failed resolve.
    expect(await db.deck_guests.count()).toBe(0);
    expect(await db.outbox.count()).toBe(0);
  });
});

describe("revokeGuest", () => {
  it("hard-deletes the local row and enqueues a delete", async () => {
    await db.deck_guests.put({
      id: "g1", deck: "deck1", user: "guest9", granted_at: "t",
    });
    await revokeGuest("g1");
    expect(await db.deck_guests.get("g1")).toBeUndefined();
    const queued = await db.outbox.toArray();
    expect(queued).toHaveLength(1);
    expect(queued[0]).toMatchObject({ type: "delete", entity: "deck_guests", recordId: "g1" });
  });

  it("grant-then-revoke coalesces to a no-op (the pending create is cancelled)", async () => {
    getFullList.mockResolvedValue([{ id: "owner1" }, { id: "guest9" }]);
    const guest = await grantGuest("deck1", "guest@posedeck.test");
    expect(await db.outbox.count()).toBe(1); // pending create

    await revokeGuest(guest.id);
    // Coalescing cancels the create; nothing reaches the server.
    expect(await db.outbox.count()).toBe(0);
    expect(await db.deck_guests.get(guest.id)).toBeUndefined();
  });
});
