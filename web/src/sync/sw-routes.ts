/**
 * Pure service-worker route predicates (M3 STEP 6).
 *
 * Kept in a plain, dependency-free module so they are unit-testable WITHOUT a
 * service-worker environment. The service worker (`src/sw.ts`) imports these to
 * decide what to do with each request.
 *
 * Caching policy (decided in the M3 plan — invariant #5 + the cross-origin
 * premise): PocketBase is CROSS-ORIGIN (`VITE_API_BASE_URL` is absolute; nginx
 * has no `/api` proxy). So the SW precaches ONLY the static app shell and is
 * **NetworkOnly** for everything API / auth / file / cross-origin. It must NEVER
 * cache:
 *  - any POST/PUT/PATCH/DELETE (only GET shell assets are cacheable);
 *  - any auth request (`/api/...`, token mints) — caching a token response is
 *    a credential leak and a correctness bug;
 *  - any cross-origin response (opaque, unbounded, and token-volatile).
 *
 * The SOLE offline-image mechanism is the explicit Dexie pin, not the SW.
 */

/** The current app origin (overridable for tests). */
export interface UrlLike {
  href: string;
  origin: string;
  pathname: string;
  protocol: string;
}

/** Parse a URL string against a base origin; returns null if unparseable. */
export function parseUrl(url: string): UrlLike | null {
  try {
    const u = new URL(url);
    return {
      href: u.href,
      origin: u.origin,
      pathname: u.pathname,
      protocol: u.protocol,
    };
  } catch {
    return null;
  }
}

/**
 * Is this a same-origin request (relative to `appOrigin`)? Cross-origin
 * requests (the PocketBase backend) are always NetworkOnly.
 */
export function isSameOrigin(url: UrlLike, appOrigin: string): boolean {
  return url.origin === appOrigin;
}

/**
 * Is this an API/auth/file request that must NEVER be cached? True for any
 * `/api/...` path (PB REST, auth, and `/api/files/...`), regardless of origin —
 * a same-origin proxy would still be NetworkOnly here.
 */
export function isApiRequest(url: UrlLike): boolean {
  return url.pathname.startsWith("/api/");
}

/**
 * Is this a navigation request (an HTML page load)? The SW answers these from
 * the precached shell so the SPA boots offline (the client-side router then
 * renders from Dexie). The caller passes the request `mode`/`destination`.
 */
export function isNavigationRequest(req: {
  mode?: string;
  destination?: string;
}): boolean {
  return req.mode === "navigate" || req.destination === "document";
}

/**
 * May this request be served from / stored in the precached shell? Only
 * same-origin GETs that are NOT API/auth requests qualify (the built JS/CSS/
 * font/image assets that make up the shell). Everything else is NetworkOnly.
 */
export function isCacheableShellRequest(
  url: UrlLike,
  method: string,
  appOrigin: string,
): boolean {
  if (method.toUpperCase() !== "GET") {
    return false;
  }
  if (url.protocol !== "http:" && url.protocol !== "https:") {
    return false;
  }
  if (!isSameOrigin(url, appOrigin)) {
    return false;
  }
  return !isApiRequest(url);
}
