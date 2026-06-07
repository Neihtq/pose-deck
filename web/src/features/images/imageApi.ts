/**
 * Card image API helpers (ARCHITECTURE.md §3.4, §5).
 *
 * Thin wrappers over the shared PocketBase client for the `card_images`
 * collection: upload a compressed blob, list a card's images ordered by
 * position, delete one, and build a display URL.
 *
 * Images stay PocketBase-direct (both upload AND delete) — they carry binary
 * payloads and are not routed through the offline outbox (M3 plan, option A).
 * We mirror the result into Dexie (`put` on upload, `delete` on delete) so the
 * local live queries that drive thumbnails and the editor stay consistent.
 */
import { db } from "@/lib/db";
import { collections, fileUrlWithToken, pb } from "@/lib/pocketbase";
import type { CardImage } from "@/lib/types";

/** Maximum number of images allowed per card. */
export const MAX_IMAGES_PER_CARD = 5;

/** Thrown when a card already has {@link MAX_IMAGES_PER_CARD} images. */
export class TooManyImagesError extends Error {
  constructor(cardId: string) {
    super(`Card ${cardId} already has the maximum of ${MAX_IMAGES_PER_CARD} images`);
    this.name = "TooManyImagesError";
  }
}

/**
 * Upload a compressed image blob as a new `card_images` record for `cardId`.
 *
 * Enforces the per-card limit ({@link MAX_IMAGES_PER_CARD}) by counting
 * existing (non-deleted) images first and throwing {@link TooManyImagesError}
 * if adding one would exceed it — the caller surfaces a message.
 *
 * @param cardId   parent card id.
 * @param blob     the compressed JPEG to upload.
 * @param position ordering position within the card.
 * @param filename optional filename for the multipart part.
 */
export async function uploadCardImage(
  cardId: string,
  blob: Blob,
  position: number,
  filename = "image.jpg",
): Promise<CardImage> {
  const existing = await listCardImages(cardId);
  if (existing.length >= MAX_IMAGES_PER_CARD) {
    throw new TooManyImagesError(cardId);
  }

  const form = new FormData();
  form.append("file", blob, filename);
  form.append("card", cardId);
  form.append("position", String(position));
  // Note: `created` is a server-managed autodate; we deliberately do NOT send
  // it (PocketBase ignores client-supplied values for it anyway).

  const record = await collections.card_images().create(form);
  // Mirror into Dexie so live queries (thumbnails, editor) reflect it at once.
  await db.card_images.put(record);
  return record;
}

/**
 * List a card's images ordered by `position` (ascending). Returns the full,
 * unpaginated list — cards hold at most {@link MAX_IMAGES_PER_CARD} images.
 */
export async function listCardImages(cardId: string): Promise<CardImage[]> {
  return collections.card_images().getFullList({
    filter: pb.filter("card = {:card}", { card: cardId }),
    sort: "position",
  });
}

/** Delete a `card_images` record by id (hard delete — images have no soft-delete). */
export async function deleteCardImage(id: string): Promise<void> {
  await collections.card_images().delete(id);
  // Mirror the hard-delete into Dexie so live queries drop the row immediately.
  await db.card_images.delete(id);
}

/**
 * Build an absolute display URL for a card image's stored file
 * (`/api/files/<collection>/<recordId>/<filename>`, ARCHITECTURE.md §5).
 *
 * `card_images` files are protected (the collection has a view rule), so the
 * URL must carry a short-lived `?token=`. This is async because minting the
 * token may hit the server; callers resolve it in an effect, not inline in JSX.
 */
export async function imageDisplayUrl(
  image: CardImage,
  queryParams?: Record<string, unknown>,
): Promise<string> {
  return fileUrlWithToken(image, image.file, queryParams);
}
