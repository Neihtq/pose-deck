/// <reference lib="webworker" />
/**
 * Service worker (M3 STEP 6) — `injectManifest` build via vite-plugin-pwa.
 *
 * Policy (M3 plan, invariant #5 + the verified cross-origin premise):
 *  - PRECACHE only the static app shell (the manifest Workbox injects below).
 *  - SPA navigation fallback: serve `index.html` from the precache for HTML
 *    navigations so the app boots offline and the client router renders from
 *    Dexie.
 *  - NetworkOnly for EVERYTHING else — all API/auth/file requests and any
 *    cross-origin (PocketBase) request. We never cache POST, auth, or
 *    cross-origin PB responses (a cached token is a credential leak; opaque
 *    cross-origin responses blow up quota). The SOLE offline-image mechanism is
 *    the explicit Dexie pin, not this worker.
 *
 * The route decisions live in the pure, unit-tested `sync/sw-routes` module.
 */
import { cleanupOutdatedCaches, precacheAndRoute } from "workbox-precaching";

import {
  isApiRequest,
  isCacheableShellRequest,
  isNavigationRequest,
  parseUrl,
} from "@/sync/sw-routes";

declare const self: ServiceWorkerGlobalScope & {
  __WB_MANIFEST: Array<{ url: string; revision: string | null }>;
};

// Precache the built shell (Workbox replaces __WB_MANIFEST at build time).
cleanupOutdatedCaches();
precacheAndRoute(self.__WB_MANIFEST);

// The precached shell's index.html, used as the SPA navigation fallback.
const SHELL_URL = "/index.html";

// Take control promptly so the offline shell is available on the next load.
self.addEventListener("install", () => {
  void self.skipWaiting();
});
self.addEventListener("activate", (event) => {
  event.waitUntil(self.clients.claim());
});

self.addEventListener("fetch", (event: FetchEvent) => {
  const { request } = event;
  const url = parseUrl(request.url);
  const appOrigin = self.location.origin;

  // SPA navigations → precached shell so the app boots offline. (Workbox's own
  // precache route already handles same-origin asset GETs; we only need to add
  // the navigation fallback and a guard that API/cross-origin requests are
  // never intercepted/cached.)
  if (isNavigationRequest(request)) {
    event.respondWith(
      (async () => {
        try {
          // Prefer the network so a deployed shell update lands immediately.
          return await fetch(request);
        } catch {
          const cached = await caches.match(SHELL_URL, {
            ignoreSearch: true,
          });
          return cached ?? Response.error();
        }
      })(),
    );
    return;
  }

  // API/auth/file or cross-origin → NetworkOnly. Do NOT call respondWith so the
  // browser performs its default (uncached) fetch; nothing is ever stored.
  if (!url || isApiRequest(url) || !isCacheableShellRequest(url, request.method, appOrigin)) {
    return;
  }

  // Same-origin shell GET not covered by the precache (rare) → network, no cache.
});
