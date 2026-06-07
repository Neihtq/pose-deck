/**
 * Stable cache keys for offline image bytes (M3 STEP 6, invariant #5).
 *
 * Protected `card_images` file URLs carry a volatile, short-lived `?token=`
 * query param (see pocketbase.ts `fileUrlWithToken`). If that token were part
 * of the offline cache key, a refreshed token would orphan every previously
 * cached blob (cache thrash). So the key is built from the STABLE parts only —
 * the collection, the record id, the filename — and deliberately:
 *
 *  - STRIPS `token` (volatile), and
 *  - PRESERVES `thumb` (a 200x200 thumbnail and the full-res file are distinct
 *    bytes and must cache under distinct keys).
 *
 * This module is intentionally pure (no Dexie, no network) so the
 * token-stripping + thumb-preservation rule is unit-tested in isolation.
 */

/** Minimal shape needed to identify a file: a record reference + its filename. */
export interface FileRef {
  id: string;
  /** Collection name (preferred) — present on SDK-fetched records. */
  collectionName?: string;
  /** Collection id — the SDK falls back to this when the name is absent. */
  collectionId?: string;
}

/** Options that affect the served bytes (hence the cache key). */
export interface BlobKeyOptions {
  /** PocketBase thumb spec, e.g. `"200x200"`. Omitted → full-resolution file. */
  thumb?: string;
}

/**
 * The collection segment of a file URL. PocketBase's `getURL` uses
 * `collectionName` when present and otherwise `collectionId`; we mirror that so
 * the key matches across fetched (named) and minimal (id-only) records. Falls
 * back to `"card_images"` since that is the only protected file collection.
 */
function collectionSegment(ref: FileRef): string {
  return ref.collectionName || ref.collectionId || "card_images";
}

/**
 * Build the stable, token-stripped, thumb-preserving cache key for a file.
 *
 * Shape: `${collection}/${recordId}/${filename}` with an optional `@thumb=…`
 * suffix when a thumbnail variant is requested. The `@`-prefixed suffix can
 * never collide with a path segment (filenames don't contain `/`, and the
 * suffix is appended after the full path), so full-res and thumbnail bytes for
 * the same file never share a key.
 */
export function blobKey(
  ref: FileRef,
  filename: string,
  opts: BlobKeyOptions = {},
): string {
  const base = `${collectionSegment(ref)}/${ref.id}/${filename}`;
  return opts.thumb ? `${base}@thumb=${opts.thumb}` : base;
}

/**
 * Derive the stable key from an already-built file URL (e.g. one carrying a
 * `?token=`). Strips `token`, preserves `thumb`, and reuses the
 * `collection/record/filename` path from the URL. Useful when only a URL string
 * is on hand. Returns `null` if the URL is not a recognizable `/api/files/…`
 * path.
 */
export function blobKeyFromUrl(url: string): string | null {
  let parsed: URL;
  try {
    parsed = new URL(url);
  } catch {
    return null;
  }
  // Path: /api/files/<collection>/<recordId>/<filename>
  const match = /\/api\/files\/([^/]+)\/([^/]+)\/([^/]+)$/.exec(
    parsed.pathname,
  );
  if (!match) {
    return null;
  }
  const [, collection, recordId, filename] = match;
  const thumb = parsed.searchParams.get("thumb") ?? undefined;
  const base = `${collection}/${decodeURIComponent(recordId)}/${decodeURIComponent(filename)}`;
  return thumb ? `${base}@thumb=${thumb}` : base;
}
