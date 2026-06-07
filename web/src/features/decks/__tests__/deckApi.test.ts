import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { db } from "@/lib/db";
import { decodeOutboxPayload } from "@/lib/outbox";
import type { Card, CardImage, Deck } from "@/lib/types";

// Mock seams. Declared via `vi.hoisted` so they are initialized BEFORE the
// hoisted `vi.mock` factories that close over them run (avoids the TDZ that a
// plain top-level `const` referenced inside a factory would hit).
const mocks = vi.hoisted(() => ({
  // `drainSync` resolves immediately so the online-only image-copy post-step
  // proceeds in tests.
  drainSync: vi.fn((): Promise<void> => Promise.resolve()),
  // `collections.cards().getOne` seam: verifies a copy card exists server-side.
  cardsGetOne: vi.fn((id: string): Promise<{ id: string }> =>
    Promise.resolve({ id }),
  ),
  // Image API seams.
  listCardImages: vi.fn(
    (_cardId: string): Promise<unknown[]> => Promise.resolve([]),
  ),
  uploadCardImage: vi.fn(
    (_cardId: string, _blob: Blob, _position: number): Promise<unknown> =>
      Promise.resolve({}),
  ),
}));
const { drainSync, cardsGetOne, listCardImages, uploadCardImage } = mocks;

vi.mock("@/sync", () => ({ wakeSync: vi.fn(), drainSync: mocks.drainSync }));

// Authenticated user so `currentUserId()` can stamp `owner`, plus the cards
// existence-check seam.
vi.mock("@/lib/pocketbase", () => ({
  pb: { authStore: { record: { id: "user1" } } },
  collections: { cards: () => ({ getOne: mocks.cardsGetOne }) },
}));

vi.mock("@/features/images/imageApi", () => {
  class TooManyImagesError extends Error {}
  return {
    listCardImages: mocks.listCardImages,
    uploadCardImage: mocks.uploadCardImage,
    imageDisplayUrl: vi.fn(
      (img: { file: string }): Promise<string> =>
        Promise.resolve(`https://files/${img.file}`),
    ),
    TooManyImagesError,
  };
});

import {
  copyDeckImages,
  createDeck,
  duplicateDeck,
  renameDeck,
  restoreDeck,
  softDeleteDeck,
} from "@/features/decks/deckApi";
import { TooManyImagesError } from "@/features/images/imageApi";

function makeDeck(id: string, deletedAt: string): Deck {
  return {
    id,
    owner: "user1",
    name: id,
    shoot_date: "",
    deleted_at: deletedAt,
    client_updated_at: "",
    created: "",
    updated: "",
  };
}

function makeCard(id: string, deck: string, position: number): Card {
  return {
    id,
    deck,
    position,
    title: id,
    time_slot: "",
    subjects: "",
    direction: "",
    notes: "",
    client_updated_at: "",
    created: "",
    updated: "",
    deleted_at: "",
  };
}

beforeEach(async () => {
  await Promise.all([db.decks.clear(), db.cards.clear(), db.outbox.clear()]);
  drainSync.mockClear();
  cardsGetOne.mockReset();
  cardsGetOne.mockImplementation(async (id: string) => ({ id }));
  listCardImages.mockReset();
  listCardImages.mockResolvedValue([]);
  uploadCardImage.mockReset();
  uploadCardImage.mockResolvedValue({});
  // Default: online + a fetch that yields a small blob.
  setOnline(true);
  vi.stubGlobal(
    "fetch",
    vi.fn(async () => ({
      ok: true,
      blob: async () => new Blob(["img"], { type: "image/jpeg" }),
    })),
  );
});

afterEach(() => {
  vi.unstubAllGlobals();
});

/** Toggle `navigator.onLine` for offline-gating tests. */
function setOnline(online: boolean): void {
  Object.defineProperty(navigator, "onLine", {
    configurable: true,
    get: () => online,
  });
}

function makeImage(id: string, card: string, position: number): CardImage {
  return { id, card, file: `${id}.jpg`, position, created: "" };
}

describe("createDeck (local-first)", () => {
  it("stamps owner from the auth store, writes Dexie + enqueues a create", async () => {
    const deck = await createDeck({ name: "Smith Wedding" });

    expect(deck.owner).toBe("user1");
    expect(deck.name).toBe("Smith Wedding");
    expect(deck.deleted_at).toBe("");
    expect(deck.client_updated_at).not.toBe("");
    // Client-supplied PB-shaped id (15 chars).
    expect(deck.id).toHaveLength(15);

    const stored = await db.decks.get(deck.id);
    expect(stored?.name).toBe("Smith Wedding");

    const entries = await db.outbox.where("recordId").equals(deck.id).toArray();
    expect(entries).toHaveLength(1);
    expect(entries[0].type).toBe("create");
    expect(entries[0].entity).toBe("decks");
    const payload = decodeOutboxPayload<{ owner: string; name: string }>(
      entries[0],
    );
    // owner MUST be carried in the create payload (load-bearing M1 fix).
    expect(payload.owner).toBe("user1");
    expect(payload.name).toBe("Smith Wedding");
  });
});

describe("renameDeck / softDeleteDeck / restoreDeck (local-first)", () => {
  it("rename writes the new name + enqueues an update", async () => {
    await db.decks.put(makeDeck("d1", ""));
    await renameDeck("d1", "Renamed");
    expect((await db.decks.get("d1"))?.name).toBe("Renamed");
    const entries = await db.outbox.where("recordId").equals("d1").toArray();
    expect(entries[0].type).toBe("update");
    expect(decodeOutboxPayload<{ name: string }>(entries[0]).name).toBe(
      "Renamed",
    );
  });

  it("softDelete sets deleted_at; restore clears it (coalesced into one update)", async () => {
    await db.decks.put(makeDeck("d1", ""));
    await softDeleteDeck("d1");
    expect((await db.decks.get("d1"))?.deleted_at).not.toBe("");
    await restoreDeck("d1");
    expect((await db.decks.get("d1"))?.deleted_at).toBe("");
    // The two updates coalesce into a single pending update entry.
    const entries = await db.outbox.where("recordId").equals("d1").toArray();
    expect(entries).toHaveLength(1);
    expect(decodeOutboxPayload<{ deleted_at: string }>(entries[0]).deleted_at).toBe(
      "",
    );
  });
});

describe("duplicateDeck (soft-deleted source guard, finding C2)", () => {
  it("refuses to duplicate a soft-deleted source deck and creates no copy", async () => {
    await db.decks.put(makeDeck("deck1", "2026-01-01T00:00:00Z"));

    await expect(duplicateDeck("deck1")).rejects.toThrow(/Trash/i);

    // Only the trashed source exists; no fresh deck/card copies were written.
    expect(await db.decks.count()).toBe(1);
    expect(await db.cards.count()).toBe(0);
    expect(await db.outbox.count()).toBe(0);
  });

  it("refuses to duplicate a missing deck", async () => {
    await expect(duplicateDeck("nope")).rejects.toThrow(/Trash/i);
  });

  it("duplicates a live source deck + its live cards into a fresh local copy", async () => {
    await db.decks.put(makeDeck("deck1", ""));
    await db.cards.bulkPut([
      makeCard("c1", "deck1", 1000),
      makeCard("c2", "deck1", 2000),
      { ...makeCard("c3", "deck1", 3000), deleted_at: "2026-01-01T00:00:00Z" },
    ]);

    const copy = await duplicateDeck("deck1");

    expect(copy.name).toBe("deck1 (copy)");
    expect(copy.deleted_at).toBe("");
    expect(copy.id).not.toBe("deck1");

    // The copy + its two LIVE cards (the trashed one is not copied).
    const copiedCards = await db.cards.where("deck").equals(copy.id).toArray();
    expect(copiedCards).toHaveLength(2);
    expect(copiedCards.map((c) => c.position).sort((a, b) => a - b)).toEqual([
      1000, 2000,
    ]);

    // Outbox: one deck create + two card creates.
    const entries = await db.outbox.toArray();
    const deckCreates = entries.filter((e) => e.entity === "decks");
    const cardCreates = entries.filter((e) => e.entity === "cards");
    expect(deckCreates).toHaveLength(1);
    expect(cardCreates).toHaveLength(2);
  });

  it("offline → duplicate still succeeds and attempts NO image upload (B3 / C2)", async () => {
    setOnline(false);
    await db.decks.put(makeDeck("deck1", ""));
    await db.cards.put(makeCard("c1", "deck1", 1000));
    listCardImages.mockResolvedValue([makeImage("img1", "c1", 0)]);

    const copy = await duplicateDeck("deck1");
    // Let the detached (gated) copy task settle.
    await Promise.resolve();
    await new Promise((r) => setTimeout(r, 0));

    expect(copy.name).toBe("deck1 (copy)");
    // Cards copied regardless; but offline means no drain/upload was attempted.
    expect(await db.cards.where("deck").equals(copy.id).count()).toBe(1);
    expect(drainSync).not.toHaveBeenCalled();
    expect(uploadCardImage).not.toHaveBeenCalled();
  });
});

describe("copyDeckImages (online-only best-effort image copy, B3 / C2)", () => {
  it("copies each source card's images to the copy card at the source position", async () => {
    listCardImages.mockImplementation(async (cardId: string) => {
      if (cardId === "src1") {
        return [makeImage("i1", "src1", 0), makeImage("i2", "src1", 1)];
      }
      return [];
    });

    await copyDeckImages([{ sourceCardId: "src1", copyCardId: "copy1" }]);

    // Drained first, verified the copy card exists, then uploaded both images.
    expect(drainSync).toHaveBeenCalledTimes(1);
    expect(cardsGetOne).toHaveBeenCalledWith("copy1");
    expect(uploadCardImage).toHaveBeenCalledTimes(2);
    // (copyCardId, blob, position) — position preserved from the source image.
    expect(uploadCardImage.mock.calls[0][0]).toBe("copy1");
    expect(uploadCardImage.mock.calls[0][2]).toBe(0);
    expect(uploadCardImage.mock.calls[1][2]).toBe(1);
  });

  it("logs and continues when a single image upload rejects (cap respected)", async () => {
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    listCardImages.mockResolvedValue([
      makeImage("i1", "src1", 0),
      makeImage("i2", "src1", 1),
      makeImage("i3", "src1", 2),
    ]);
    // The middle image trips the per-card 5-image cap; the rest still upload.
    uploadCardImage
      .mockResolvedValueOnce({})
      .mockRejectedValueOnce(new TooManyImagesError("copy1"))
      .mockResolvedValueOnce({});

    await copyDeckImages([{ sourceCardId: "src1", copyCardId: "copy1" }]);

    // All three were attempted; the rejection did not abort the loop.
    expect(uploadCardImage).toHaveBeenCalledTimes(3);
    expect(warn).toHaveBeenCalled();
    warn.mockRestore();
  });

  it("skips a copy card that does not yet exist server-side (404), no upload", async () => {
    cardsGetOne.mockRejectedValue(new Error("404"));
    listCardImages.mockResolvedValue([makeImage("i1", "src1", 0)]);

    await copyDeckImages([{ sourceCardId: "src1", copyCardId: "copy1" }]);

    expect(uploadCardImage).not.toHaveBeenCalled();
  });

  it("offline → does not drain or upload", async () => {
    setOnline(false);
    listCardImages.mockResolvedValue([makeImage("i1", "src1", 0)]);

    await copyDeckImages([{ sourceCardId: "src1", copyCardId: "copy1" }]);

    expect(drainSync).not.toHaveBeenCalled();
    expect(uploadCardImage).not.toHaveBeenCalled();
  });
});

describe("duplicateDeck name clamp", () => {
  it("clamps the copy name to the 200-char DB ceiling (finding spec-dup-name-overflow)", async () => {
    // A source name at the 200-char ceiling: `<name> (copy)` would be 207 chars
    // and the server (ARCHITECTURE.md §3.2, max 200) rejects it with a 400.
    const longName = "x".repeat(200);
    await db.decks.put({ ...makeDeck("deck1", ""), name: longName });

    const copy = await duplicateDeck("deck1");

    expect(copy.name.length).toBeLessThanOrEqual(200);
    expect(copy.name.endsWith(" (copy)")).toBe(true);

    // The create payload (what the sync engine sends verbatim) is also clamped.
    const entries = await db.outbox.where("recordId").equals(copy.id).toArray();
    const payload = decodeOutboxPayload<{ name: string }>(entries[0]);
    expect(payload.name.length).toBeLessThanOrEqual(200);
    expect(payload.name.endsWith(" (copy)")).toBe(true);
  });
});
