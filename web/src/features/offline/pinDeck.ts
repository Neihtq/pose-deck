/**
 * "Download for offline" — explicit Dexie pin of a deck's images (M3 STEP 6).
 *
 * The service worker only precaches the static app shell and is NetworkOnly for
 * every API/auth/file request (PocketBase is cross-origin), so this Dexie pin is
 * the SOLE mechanism that makes a deck's images render with no network. Pinning
 * a deck:
 *
 *  1. records the pin in `pinned_decks`;
 *  2. walks the deck's live cards (from Dexie — local-first) and each card's
 *     images, fetching the bytes of every cached size variant (the on-screen
 *     thumb sizes + the full-res file) through the protected token URL; and
 *  3. stores those bytes in `image_blobs` under a token-stripped, thumb-
 *     preserving key (see offlineKeys.blobKey).
 *
 * Pinning reads the deck's rows that are ALREADY in Dexie (local-first) and
 * only writes `image_blobs` — it never re-writes deck/card rows, so it cannot
 * clobber a row a pending outbox mutation just edited (the pin-clobbers-pending
 * hole the M3 plan calls out). Only image BYTES are added.
 * Unpinning removes the pin and every blob whose card belongs to the deck. A
 * reconciling refresh re-fetches the current image set and deletes orphaned
 * blobs (images deleted since the last pin). The pinned-image COUNT is always
 * derived from `image_blobs.count()`, never an in-memory counter.
 */
import { type PoseDeckDB, db as defaultDb } from "@/lib/db";
import { liveCardImages, liveCards } from "@/lib/localStore";
import { blobKey } from "@/lib/offlineKeys";
import { fileUrlWithToken } from "@/lib/pocketbase";
import type { CardImage } from "@/lib/types";

/**
 * The size variants we cache per image. The empty `thumb` is the full-res file;
 * the others mirror the thumb specs the UI requests so a pinned deck renders
 * without a network round-trip in the deck list, deck detail, and editor.
 */
export const CACHED_THUMB_SIZES: readonly (string | undefined)[] = [
  undefined, // full resolution
  "200x200", // deck-detail row + deck-list-card thumbnails resolve at ≤ this
  "300x300", // card editor gallery
  "400x300", // deck-list auto-thumbnail
] as const;

/**
 * Fetch the bytes at a (token-carrying) URL as a Blob. Injectable so tests can
 * stub the network without a live PocketBase. Defaults to the global `fetch`.
 */
export type BlobFetcher = (url: string) => Promise<Blob>;

const defaultFetchBlob: BlobFetcher = async (url) => {
  const res = await fetch(url);
  if (!res.ok) {
    throw new Error(`Failed to fetch image bytes: ${res.status}`);
  }
  return res.blob();
};

/** Dependencies for the pin operations, injectable for tests. */
export interface PinDeps {
  database?: PoseDeckDB;
  fetchBlob?: BlobFetcher;
  /** Mint a token URL for a file (defaults to the live PB token-URL builder). */
  urlFor?: (
    image: CardImage,
    opts: { thumb?: string },
  ) => Promise<string>;
}

function resolveDeps(deps: PinDeps): Required<PinDeps> {
  return {
    database: deps.database ?? defaultDb,
    fetchBlob: deps.fetchBlob ?? defaultFetchBlob,
    urlFor:
      deps.urlFor ??
      ((image, opts) => fileUrlWithToken(image, image.file, opts)),
  };
}

/** Is the given deck currently pinned for offline use? */
export async function isPinned(
  deckId: string,
  deps: PinDeps = {},
): Promise<boolean> {
  const { database } = resolveDeps(deps);
  return (await database.pinned_decks.get(deckId)) !== undefined;
}

/** All image records under a deck (across its live cards), ordered per card. */
async function deckImages(
  database: PoseDeckDB,
  deckId: string,
): Promise<CardImage[]> {
  const cards = await liveCards(database, deckId);
  const perCard = await Promise.all(
    cards.map((card) => liveCardImages(database, card.id)),
  );
  return perCard.flat();
}

/**
 * Cache every size variant of one image's bytes into `image_blobs`. Best-effort
 * per variant — a single failed fetch (e.g. a 4xx for an absent thumb) does not
 * abort the others, so a partial pin still caches what it can.
 */
async function cacheImage(
  deps: Required<PinDeps>,
  image: CardImage,
): Promise<void> {
  await Promise.all(
    CACHED_THUMB_SIZES.map(async (thumb) => {
      const opts = thumb ? { thumb } : {};
      const key = blobKey(image, image.file, opts);
      try {
        const url = await deps.urlFor(image, opts);
        const blob = await deps.fetchBlob(url);
        await deps.database.image_blobs.put({
          key,
          card: image.card,
          recordId: image.id,
          blob,
          cachedAt: Date.now(),
        });
      } catch {
        // Skip this variant; pinning is best-effort per size.
      }
    }),
  );
}

/**
 * Pin `deckId` for offline use: record the pin and cache every image's bytes.
 * Idempotent — re-pinning refreshes the cached bytes via {@link refreshPin}.
 * Returns the number of distinct images cached (derived from the deck's images,
 * not an in-memory counter).
 */
export async function pinDeck(
  deckId: string,
  deps: PinDeps = {},
): Promise<number> {
  const resolved = resolveDeps(deps);
  await resolved.database.pinned_decks.put({ deckId, pinnedAt: Date.now() });
  const images = await deckImages(resolved.database, deckId);
  for (const image of images) {
    await cacheImage(resolved, image);
  }
  return images.length;
}

/**
 * Unpin `deckId`: remove the pin and every cached blob belonging to one of the
 * deck's cards. Uses the `image_blobs.card` index to evict in bulk without
 * scanning the whole table.
 */
export async function unpinDeck(
  deckId: string,
  deps: PinDeps = {},
): Promise<void> {
  const { database } = resolveDeps(deps);
  await database.pinned_decks.delete(deckId);
  const cards = await database.cards.where("deck").equals(deckId).toArray();
  for (const card of cards) {
    await database.image_blobs.where("card").equals(card.id).delete();
  }
}

/**
 * Reconcile a pinned deck's cached bytes against its CURRENT image set:
 * re-cache present images and DELETE blobs for images that no longer exist
 * (deleted since the last pin). A no-op if the deck is not pinned. This only
 * touches `image_blobs`; the deck/card rows are already in Dexie locally.
 */
export async function refreshPin(
  deckId: string,
  deps: PinDeps = {},
): Promise<void> {
  const resolved = resolveDeps(deps);
  if (!(await isPinned(deckId, deps))) {
    return;
  }
  const images = await deckImages(resolved.database, deckId);
  const liveRecordIds = new Set(images.map((i) => i.id));

  // Prune blobs whose source image is gone. Scope to this deck's cards so we
  // never touch another deck's cache.
  const cards = await resolved.database.cards
    .where("deck")
    .equals(deckId)
    .toArray();
  for (const card of cards) {
    const stale = await resolved.database.image_blobs
      .where("card")
      .equals(card.id)
      .filter((b) => !liveRecordIds.has(b.recordId))
      .primaryKeys();
    if (stale.length > 0) {
      await resolved.database.image_blobs.bulkDelete(stale);
    }
  }

  // Refresh the bytes of every present image.
  for (const image of images) {
    await cacheImage(resolved, image);
  }
}

/** Count of cached image-byte rows for a deck (derived, not a counter). */
export async function pinnedBlobCount(
  deckId: string,
  deps: PinDeps = {},
): Promise<number> {
  const { database } = resolveDeps(deps);
  const cards = await database.cards.where("deck").equals(deckId).toArray();
  let total = 0;
  for (const card of cards) {
    total += await database.image_blobs.where("card").equals(card.id).count();
  }
  return total;
}
