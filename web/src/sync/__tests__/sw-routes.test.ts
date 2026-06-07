/**
 * Unit tests for the pure service-worker route predicates (M3 STEP 6).
 *
 * These guard the caching policy decided in the M3 plan: precache only the
 * same-origin static shell; NetworkOnly for every API/auth/file request and any
 * cross-origin (PocketBase) request. The predicates must never classify a POST,
 * an `/api/...` request, or a cross-origin request as cacheable.
 */
import { describe, expect, it } from "vitest";

import {
  isApiRequest,
  isCacheableShellRequest,
  isNavigationRequest,
  isSameOrigin,
  parseUrl,
} from "../sw-routes";

const APP_ORIGIN = "https://app.example.com";
const PB_ORIGIN = "https://api.example.com";

function url(s: string) {
  const u = parseUrl(s);
  if (!u) throw new Error(`unparseable: ${s}`);
  return u;
}

describe("parseUrl", () => {
  it("returns null for an unparseable URL", () => {
    expect(parseUrl("::::not a url")).toBeNull();
  });
});

describe("isSameOrigin", () => {
  it("is true for same-origin and false for cross-origin", () => {
    expect(isSameOrigin(url(`${APP_ORIGIN}/assets/x.js`), APP_ORIGIN)).toBe(true);
    expect(isSameOrigin(url(`${PB_ORIGIN}/api/x`), APP_ORIGIN)).toBe(false);
  });
});

describe("isApiRequest", () => {
  it("matches any /api/ path on either origin", () => {
    expect(isApiRequest(url(`${PB_ORIGIN}/api/collections/decks/records`))).toBe(
      true,
    );
    expect(isApiRequest(url(`${PB_ORIGIN}/api/files/card_images/x/p.jpg`))).toBe(
      true,
    );
    expect(isApiRequest(url(`${APP_ORIGIN}/api/health`))).toBe(true);
  });

  it("does not match shell asset paths", () => {
    expect(isApiRequest(url(`${APP_ORIGIN}/assets/index-abc.js`))).toBe(false);
    expect(isApiRequest(url(`${APP_ORIGIN}/index.html`))).toBe(false);
  });
});

describe("isNavigationRequest", () => {
  it("matches navigate mode or document destination", () => {
    expect(isNavigationRequest({ mode: "navigate" })).toBe(true);
    expect(isNavigationRequest({ destination: "document" })).toBe(true);
    expect(isNavigationRequest({ mode: "cors", destination: "script" })).toBe(
      false,
    );
  });
});

describe("isCacheableShellRequest", () => {
  it("accepts same-origin non-API GETs (the shell)", () => {
    expect(
      isCacheableShellRequest(url(`${APP_ORIGIN}/assets/index.js`), "GET", APP_ORIGIN),
    ).toBe(true);
    expect(
      isCacheableShellRequest(url(`${APP_ORIGIN}/index.html`), "GET", APP_ORIGIN),
    ).toBe(true);
  });

  it("rejects non-GET methods (never cache a mutation)", () => {
    for (const method of ["POST", "PUT", "PATCH", "DELETE"]) {
      expect(
        isCacheableShellRequest(url(`${APP_ORIGIN}/assets/x.js`), method, APP_ORIGIN),
      ).toBe(false);
    }
  });

  it("rejects same-origin /api/ requests (auth/REST/files)", () => {
    expect(
      isCacheableShellRequest(url(`${APP_ORIGIN}/api/files/x/y/z.jpg`), "GET", APP_ORIGIN),
    ).toBe(false);
  });

  it("rejects cross-origin requests (the PocketBase backend)", () => {
    expect(
      isCacheableShellRequest(url(`${PB_ORIGIN}/api/files/x/y/z.jpg`), "GET", APP_ORIGIN),
    ).toBe(false);
    // Even a cross-origin non-API GET (e.g. a CDN) is NetworkOnly here.
    expect(
      isCacheableShellRequest(url(`${PB_ORIGIN}/logo.png`), "GET", APP_ORIGIN),
    ).toBe(false);
  });

  it("rejects non-http(s) schemes (e.g. chrome-extension, data)", () => {
    expect(
      isCacheableShellRequest(url("data:text/plain,hi"), "GET", APP_ORIGIN),
    ).toBe(false);
  });
});
