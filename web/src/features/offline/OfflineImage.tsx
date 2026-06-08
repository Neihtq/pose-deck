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

import {
  type ImageHandle,
  type NetworkUrlResolver,
  resolveImage,
} from "@/lib/offlineImages";
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
  // `release` for the currently-adopted handle. BOTH the effect cleanup and the
  // error path revoke through this ref so a re-resolved (possibly now-pinned)
  // blob URL is always paired with a revoke and never leaks.
  const releaseRef = React.useRef<() => void>(() => {});
  // Cleared on unmount so async resolves (effect or error path) don't adopt a
  // handle or setState on a dead component.
  const mountedRef = React.useRef(true);
  // Monotonic tag for the current resolve cycle. The effect bumps it on every
  // run (image/opts change); async resolves capture the value live at the call
  // site and only adopt while it still matches. A single shared `mountedRef`
  // boolean can't distinguish cycles: a cleanup flips it false, then the next
  // effect flips it true again, so an in-flight resolve from the OLD cycle (e.g.
  // the error-path token refresh) could otherwise adopt a STALE variant into the
  // remounted cycle, briefly showing the wrong image.
  const generationRef = React.useRef(0);

  const opts = React.useMemo(
    () => ({ ...(thumb ? { thumb } : {}), networkUrl }),
    [thumb, networkUrl],
  );

  // Adopt a freshly-resolved handle as the live source: revoke the previously
  // adopted handle, then take ownership of the new one. The caller passes the
  // `generation` it captured before awaiting; if the component has unmounted OR
  // a newer resolve cycle has started, self-release the new handle instead (no
  // leak, no late setState, no stale-variant adoption).
  const adopt = React.useCallback(
    (handle: ImageHandle, generation: number): void => {
      if (!mountedRef.current || generation !== generationRef.current) {
        // Resolved after unmount or superseded by a newer cycle: revoke
        // immediately so the blob URL can't leak.
        handle.release();
        return;
      }
      releaseRef.current();
      releaseRef.current = handle.release;
      fromCacheRef.current = handle.fromCache;
      setUrl(handle.url);
    },
    [],
  );

  // Resolve (and re-resolve on image/thumb change) the handle, owning revoke.
  React.useEffect(() => {
    mountedRef.current = true;
    const generation = ++generationRef.current;
    (async () => {
      adopt(await resolveImage(image, opts), generation);
    })();
    return () => {
      // Tear down this resolve cycle: stop adopting and revoke the live handle.
      mountedRef.current = false;
      releaseRef.current();
      releaseRef.current = () => {};
    };
    // `image.id`/`image.file` identify the bytes; `opts` carries the thumb.
  }, [image.id, image.file, opts, adopt]);

  // Re-mint a fresh token URL when a NETWORK image fails to load (expired
  // token). A cached blob never expires, so we skip the retry for it.
  const handleError = React.useCallback(async () => {
    if (fromCacheRef.current) {
      return;
    }
    // Capture the cycle this error belongs to BEFORE awaiting: if image/opts
    // change while the token mints, the resolve must not adopt into the new
    // cycle (it would show the stale variant until the new cycle's own resolve).
    const generation = generationRef.current;
    const handle = await resolveImage(image, opts);
    if (
      !mountedRef.current ||
      generation !== generationRef.current ||
      handle.url === url
    ) {
      // Unmounted, superseded by a newer cycle, or unchanged URL (a genuine
      // error, e.g. 404). Either way the handle is not adopted, so release it
      // now to avoid leaking/looping.
      handle.release();
      return;
    }
    adopt(handle, generation);
  }, [image, opts, url, adopt]);

  if (url === null) {
    return <>{fallback}</>;
  }

  return <img src={url} alt={alt} onError={() => void handleError()} {...imgProps} />;
}
