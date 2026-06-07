/**
 * Unit tests for the offline pin (M3 STEP 6): pin / unpin / reconcile.
 *
 * Uses fake-indexeddb (a fresh PoseDeckDB per test) and STUBS the byte fetch +
 * token-URL builder so nothing hits the network. Asserts:
 *  - pinning records the pin and caches every size variant under stable keys;
 *  - the pinned count is DERIVED from `image_blobs` (not an in-memory counter);
 *  - unpinning removes the pin and the deck's blobs (scoped to the deck);
 *  - a reconciling refresh prunes blobs for images deleted since the last pin.
 */
import { beforeEach, describe, expect, it, vi } from "vitest";

import { PoseDeckDB } from "@/lib/db";
import { blobKey } from "@/lib/offlineKeys";
import type { Card, CardImage, Deck } from "@/lib/types";
import {
  CACHED_THUMB_SIZES,
  isPinned,
  pinDeck,
  pinnedBlobCount,
  refreshPin,
  unpinDeck,
} from "../pinDeck";

const DECK: Deck = {
  id: "deck1",
  owner: "u1",
  name: "Shoot",
  shoot_date: "",
  client_updated_at: "",
  created: "",
  updated: "",
  deleted_at: "",
};

function card(id: string, deck = "deck1", position = 1000): Card {
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

function image(id: string, cardId: string, position = 0): CardImage {
  return {
    id,
    card: cardId,
    file: `${id}.jpg`,
    position,
    created: "",
    collectionName: "card_images",
  } as CardImage;
}

let db: PoseDeckDB;
let fetchBlob: ReturnType<typeof vi.fn>;
let urlFor: ReturnType<typeof vi.fn>;

function deps() {
  return { database: db, fetchBlob, urlFor };
}

beforeEach(async () => {
  db = new PoseDeckDB(`test-${crypto.randomUUID()}`);
  await db.open();
  fetchBlob = vi.fn(async () => new Blob(["bytes"], { type: "image/jpeg" }));
  // Echo back a deterministic, token-carrying URL.
  urlFor = vi.fn(async (img: CardImage, opts: { thumb?: string }) =>
    `/api/files/card_images/${img.id}/${img.file}${
      opts.thumb ? `?thumb=${opts.thumb}` : ""
    }`,
  );
});

describe("pinDeck", () => {
  it("records the pin and caches every size variant of each image", async () => {
    await db.decks.put(DECK);
    await db.cards.bulkPut([card("card1"), card("card2", "deck1", 2000)]);
    await db.card_images.bulkPut([image("img1", "card1"), image("img2", "card2")]);

    const count = await pinDeck("deck1", deps());

    expect(await isPinned("deck1", deps())).toBe(true);
    // Two images.
    expect(count).toBe(2);
    // Each image cached once per size variant.
    expect(await db.image_blobs.count()).toBe(2 * CACHED_THUMB_SIZES.length);
    // Keys are the stable, token-stripped keys.
    const fullKey = blobKey(image("img1", "card1"), "img1.jpg");
    expect(await db.image_blobs.get(fullKey)).toBeDefined();
    // Bytes were fetched via the token URL, never embedding a token in the key.
    expect(fetchBlob).toHaveBeenCalled();
    for (const key of (await db.image_blobs.toCollection().primaryKeys()) as string[]) {
      expect(key).not.toContain("token");
    }
  });

  it("derives the pinned count from image_blobs, not a counter", async () => {
    await db.decks.put(DECK);
    await db.cards.put(card("card1"));
    await db.card_images.put(image("img1", "card1"));

    await pinDeck("deck1", deps());
    expect(await pinnedBlobCount("deck1", deps())).toBe(CACHED_THUMB_SIZES.length);
  });

  it("is best-effort: a failed variant fetch does not abort the others", async () => {
    await db.decks.put(DECK);
    await db.cards.put(card("card1"));
    await db.card_images.put(image("img1", "card1"));
    // Fail the full-res fetch; thumbs still cache.
    fetchBlob.mockImplementation(async (url: string) => {
      if (!url.includes("thumb")) throw new Error("boom");
      return new Blob(["t"]);
    });

    await pinDeck("deck1", deps());
    expect(await db.image_blobs.count()).toBe(CACHED_THUMB_SIZES.length - 1);
  });
});

describe("unpinDeck", () => {
  it("removes the pin and the deck's blobs only", async () => {
    await db.decks.bulkPut([DECK, { ...DECK, id: "deck2" }]);
    await db.cards.bulkPut([card("card1", "deck1"), card("cardX", "deck2")]);
    await db.card_images.bulkPut([
      image("img1", "card1"),
      image("imgX", "cardX"),
    ]);
    await pinDeck("deck1", deps());
    await pinDeck("deck2", deps());
    const before = await db.image_blobs.count();
    expect(before).toBe(2 * CACHED_THUMB_SIZES.length);

    await unpinDeck("deck1", deps());

    expect(await isPinned("deck1", deps())).toBe(false);
    expect(await isPinned("deck2", deps())).toBe(true);
    // Only deck1's blobs are gone; deck2's remain.
    expect(await db.image_blobs.count()).toBe(CACHED_THUMB_SIZES.length);
    expect(await pinnedBlobCount("deck2", deps())).toBe(CACHED_THUMB_SIZES.length);
  });
});

describe("refreshPin", () => {
  it("prunes blobs for an image deleted since the last pin", async () => {
    await db.decks.put(DECK);
    await db.cards.put(card("card1"));
    await db.card_images.bulkPut([image("img1", "card1"), image("img2", "card1")]);
    await pinDeck("deck1", deps());
    expect(await db.image_blobs.count()).toBe(2 * CACHED_THUMB_SIZES.length);

    // img2 is deleted (mirrors a hard-delete of a card_images row).
    await db.card_images.delete("img2");
    await refreshPin("deck1", deps());

    // img2's blobs are pruned; img1's remain (and were refreshed).
    expect(await db.image_blobs.count()).toBe(CACHED_THUMB_SIZES.length);
    const survivingRecordIds = new Set(
      (await db.image_blobs.toArray()).map((b) => b.recordId),
    );
    expect(survivingRecordIds).toEqual(new Set(["img1"]));
  });

  it("is a no-op for a deck that is not pinned", async () => {
    await db.decks.put(DECK);
    await db.cards.put(card("card1"));
    await db.card_images.put(image("img1", "card1"));

    await refreshPin("deck1", deps());
    expect(await db.image_blobs.count()).toBe(0);
    expect(fetchBlob).not.toHaveBeenCalled();
  });
});
