/**
 * `<OfflineImage>` — renders a card image from the offline pin when available,
 * else from the network token URL (M3 STEP 6, invariant #5).
 *
 * Resolves a `{ url, release }` handle via {@link resolveImage} and owns its
 * lifecycle: the object URL of a pinned blob is REVOKED on unmount and whenever
 * the resolved url changes, so blob URLs never leak. While resolving (or if the
 * deck is not pinned and we have no network) it renders the `fallback`.
 *
 * Token freshness: a network (un-pinned) image carries a short-lived `?token=`;
 * if the `<img>` fails to load (token expired on a long-lived view) we re-resolve
 * once for a fresh URL, mirroring the existing thumbnail-refresh handlers. We
 * guard the loop by only re-resolving when not serving from cache (a cached blob
 * never expires) and only updating state when the URL actually changes.
 */
import * as React from "react";

import { type NetworkUrlResolver, resolveImage } from "@/lib/offlineImages";
import type { CardImage } from "@/lib/types";

export interface OfflineImageProps
  extends Omit<React.ImgHTMLAttributes<HTMLImageElement>, "src"> {
  /** The card image to display. */
  image: CardImage;
  /** PocketBase thumb spec (e.g. `"200x200"`); omit for full resolution. */
  thumb?: string;
  /** Rendered while the source is resolving / unavailable. */
  fallback?: React.ReactNode;
  /**
   * Network-URL resolver for the un-pinned path (defaults to a fresh token URL).
   * Callers pass `imageApi.imageDisplayUrl` so its token-refresh behavior is
   * reused for network images.
   */
  networkUrl?: NetworkUrlResolver;
}

export function OfflineImage({
  image,
  thumb,
  fallback = null,
  networkUrl,
  alt = "",
  ...imgProps
}: OfflineImageProps): React.JSX.Element {
  const [url, setUrl] = React.useState<string | null>(null);
  // Tracks whether the current url is a cached object URL (don't retry on error).
  const fromCacheRef = React.useRef(false);

  const opts = React.useMemo(
    () => ({ ...(thumb ? { thumb } : {}), networkUrl }),
    [thumb, networkUrl],
  );

  // Resolve (and re-resolve on image/thumb change) the handle, owning revoke.
  React.useEffect(() => {
    let cancelled = false;
    let release = (): void => {};
    (async () => {
      const handle = await resolveImage(image, opts);
      if (cancelled) {
        // Resolved after unmount: revoke immediately so the blob URL can't leak.
        handle.release();
        return;
      }
      release = handle.release;
      fromCacheRef.current = handle.fromCache;
      setUrl(handle.url);
    })();
    return () => {
      cancelled = true;
      release();
    };
    // `image.id`/`image.file` identify the bytes; `opts` carries the thumb.
  }, [image.id, image.file, opts]);

  // Re-mint a fresh token URL when a NETWORK image fails to load (expired
  // token). A cached blob never expires, so we skip the retry for it.
  const handleError = React.useCallback(async () => {
    if (fromCacheRef.current) {
      return;
    }
    const handle = await resolveImage(image, opts);
    fromCacheRef.current = handle.fromCache;
    setUrl((prev) => {
      if (prev === handle.url) {
        // Unchanged URL → a genuine error (e.g. 404). Don't loop; release.
        handle.release();
        return prev;
      }
      return handle.url;
    });
  }, [image, opts]);

  if (url === null) {
    return <>{fallback}</>;
  }

  return <img src={url} alt={alt} onError={() => void handleError()} {...imgProps} />;
}
