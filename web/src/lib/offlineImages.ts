/**
 * Offline-aware image source resolution (M3 STEP 6, invariant #5).
 *
 * `resolveImage` returns a HANDLE — `{ url, release }` — for a card image:
 *
 *  - If the image's bytes are pinned in Dexie (`image_blobs`), `url` is an
 *    object URL over the cached blob (`URL.createObjectURL`) and `release()`
 *    REVOKES it. The caller (the `<OfflineImage>` component) owns the handle's
 *    lifecycle and must call `release()` on unmount / url-change, or the object
 *    URL leaks for the lifetime of the document.
 *  - Otherwise `url` is the network token URL (minted via `fileUrlWithToken`)
 *    and `release()` is a no-op (there is nothing to revoke).
 *
 * Returning a handle (rather than a raw blob URL) keeps the revoke paired with
 * the create at one call site, so the caller can't accidentally leak or
 * double-revoke. The cache key strips the volatile `?token=` and preserves
 * `thumb` (see offlineKeys.blobKey) so a refreshed token never misses the pin.
 */
import { type PoseDeckDB, db as defaultDb } from "./db";
import { type BlobKeyOptions, blobKey } from "./offlineKeys";
import { fileUrlWithToken } from "./pocketbase";
import type { CardImage } from "./types";

/** A resolved image source plus the cleanup the caller must run when done. */
export interface ImageHandle {
  /** The `<img src>` to use (object URL for a pinned blob, else a token URL). */
  url: string;
  /** Revokes the object URL when pinned; a no-op for a network URL. */
  release(): void;
  /** True when `url` is a cached-blob object URL (mostly for tests/diagnostics). */
  fromCache: boolean;
}

/**
 * Builds the NETWORK (token-carrying) URL for an image's file. The options bag
 * is `Record<string, unknown>` so the existing `imageApi.imageDisplayUrl` /
 * `fileUrlWithToken` signatures slot in directly; in practice it carries only
 * `{ thumb? }`.
 */
export type NetworkUrlResolver = (
  image: CardImage,
  opts: Record<string, unknown>,
) => Promise<string>;

const NOOP = (): void => {};

/** Default network resolver: a fresh token URL via the shared PB client. */
const defaultNetworkUrl: NetworkUrlResolver = (image, opts) =>
  fileUrlWithToken(image, image.file, opts);

/** Options for {@link resolveImage}. */
export interface ResolveImageOptions extends BlobKeyOptions {
  /** Injectable Dexie handle (defaults to the shared singleton). */
  database?: PoseDeckDB;
  /**
   * Injectable network-URL resolver for the un-pinned path. Defaults to a fresh
   * token URL; callers (e.g. `<OfflineImage>`) pass the feature-layer
   * `imageApi.imageDisplayUrl` so its token-refresh behavior + tests are reused.
   */
  networkUrl?: NetworkUrlResolver;
}

/**
 * Resolve the best source for `image`: the pinned blob if present, otherwise
 * the network token URL. `opts.thumb` selects a thumbnail variant; it is part
 * of both the cache key and the network URL so the two stay consistent.
 */
export async function resolveImage(
  image: CardImage,
  opts: ResolveImageOptions = {},
): Promise<ImageHandle> {
  const { database = defaultDb, networkUrl = defaultNetworkUrl, thumb } = opts;
  const keyOpts: BlobKeyOptions = thumb ? { thumb } : {};
  const key = blobKey(image, image.file, keyOpts);
  const cached = await database.image_blobs.get(key);
  if (cached) {
    const objectUrl = URL.createObjectURL(cached.blob);
    return {
      url: objectUrl,
      fromCache: true,
      release: () => URL.revokeObjectURL(objectUrl),
    };
  }
  // Pass a plain record so the resolver's `Record<string, unknown>` param fits.
  const url = await networkUrl(image, thumb ? { thumb } : {});
  return { url, fromCache: false, release: NOOP };
}
