/**
 * Unit tests for the injectable image-byte resolver (jsdom env: needs FileReader
 * + fake-indexeddb; NO live PocketBase).
 *
 *  - resolveAllImages: over an INJECTED fake resolver, builds the right Map and
 *    calls the resolver exactly once per (de-duped) image id, counting drops.
 *  - resolveImageBytes (default): cache-hit reads bytes from `image_blobs` under
 *    the EXACT key the resolver computes (no network); network fallback fetches
 *    via the injected token URL; `!ok`/throw fail-soft to `undefined` (no throw);
 *    a 401 triggers a one-shot token refresh + retry.
 */
import { PoseDeckDB } from "@/lib/db";
import { blobKey } from "@/lib/offlineKeys";
import type { CardImage } from "@/lib/types";
import { beforeEach, describe, expect, it, vi } from "vitest";

import {
  type ImageBytesResolver,
  resolveAllImages,
  resolveImageBytes,
} from "../imageResolver";

function image(id: string, card = "c1", position = 0): CardImage {
  return { id, card, position, file: `${id}.jpg`, created: "", collectionName: "card_images" };
}

describe("resolveAllImages", () => {
  it("returns a Map of data URLs and calls the resolver once per image id", async () => {
    const resolver = vi.fn<ImageBytesResolver>(async (img) => `data:image/jpeg;base64,${img.id}`);
    const images = [image("a"), image("b"), image("c")];
    const { sources, dropped } = await resolveAllImages(images, resolver, 2);

    expect(resolver).toHaveBeenCalledTimes(3);
    expect(sources.get("a")).toBe("data:image/jpeg;base64,a");
    expect(sources.get("b")).toBe("data:image/jpeg;base64,b");
    expect(sources.get("c")).toBe("data:image/jpeg;base64,c");
    expect(dropped).toBe(0);
  });

  it("de-dupes repeated image ids (resolves each once)", async () => {
    const resolver = vi.fn<ImageBytesResolver>(async (img) => `url:${img.id}`);
    const images = [image("a"), image("a"), image("b")];
    await resolveAllImages(images, resolver);
    expect(resolver).toHaveBeenCalledTimes(2);
  });

  it("counts undefined results as dropped", async () => {
    const resolver = vi.fn<ImageBytesResolver>(async (img) =>
      img.id === "b" ? undefined : `url:${img.id}`,
    );
    const { sources, dropped } = await resolveAllImages([image("a"), image("b")], resolver);
    expect(sources.get("b")).toBeUndefined();
    expect(dropped).toBe(1);
  });
});

describe("resolveImageBytes (default, fail-soft)", () => {
  let db: PoseDeckDB;

  beforeEach(async () => {
    db = new PoseDeckDB(`test-resolver-${Math.random().toString(36).slice(2)}`);
    await db.open();
  });

  it("CACHE HIT: looks up image_blobs under the full-res key and uses NO network", async () => {
    // NOTE: fake-indexeddb degrades a stored Blob to a plain object on read (the
    // structured-clone polyfill doesn't preserve Blob), so we can't assert the
    // FileReader-produced data URL here — that conversion is covered by the
    // network-fallback test, which uses a freshly-constructed in-test Blob. What
    // matters for the cache-FIRST contract is that a hit under the EXACT full-res
    // key the resolver computes short-circuits the network entirely.
    const img = image("img1");
    const key = blobKey(img, img.file); // full-res, no thumb — must match resolver
    await db.image_blobs.put({
      key,
      card: img.card,
      recordId: img.id,
      blob: new Blob(["JPEGBYTES"], { type: "image/jpeg" }),
      cachedAt: Date.now(),
    });
    const fetchImpl = vi.fn();
    const tokenUrl = vi.fn(async () => "http://pb/api/files/x?token=t");

    await resolveImageBytes(img, {
      database: db,
      fetchImpl: fetchImpl as unknown as typeof fetch,
      tokenUrl,
    });

    expect(fetchImpl).not.toHaveBeenCalled();
    expect(tokenUrl).not.toHaveBeenCalled();
  });

  it("CACHE MISS under a DIFFERENT key falls through to the network", async () => {
    const img = image("img1b");
    // Seed a blob under the THUMB key — the resolver uses the full-res key, so
    // this must be a miss and fall through to fetch (guards the key contract).
    await db.image_blobs.put({
      key: blobKey(img, img.file, { thumb: "200x200" }),
      card: img.card,
      recordId: img.id,
      blob: new Blob(["X"], { type: "image/jpeg" }),
      cachedAt: Date.now(),
    });
    const fetchImpl = vi.fn(async () => ({
      ok: true,
      status: 200,
      blob: async () => new Blob(["B"], { type: "image/jpeg" }),
    }));
    const url = await resolveImageBytes(img, {
      database: db,
      fetchImpl: fetchImpl as unknown as typeof fetch,
      tokenUrl: async () => "http://pb/x",
    });
    expect(fetchImpl).toHaveBeenCalledTimes(1);
    expect(url).toMatch(/^data:image\/jpeg;base64,/);
  });

  it("NETWORK FALLBACK: empty cache → fetch the token URL → data URL", async () => {
    const img = image("img2");
    const tokenUrl = vi.fn(async () => "http://pb/api/files/x?token=t");
    const fetchImpl = vi.fn(async () => ({
      ok: true,
      status: 200,
      blob: async () => new Blob(["BYTES"], { type: "image/jpeg" }),
    }));

    const url = await resolveImageBytes(img, {
      database: db,
      fetchImpl: fetchImpl as unknown as typeof fetch,
      tokenUrl,
    });

    expect(tokenUrl).toHaveBeenCalledTimes(1);
    expect(fetchImpl).toHaveBeenCalledWith("http://pb/api/files/x?token=t");
    expect(url).toMatch(/^data:image\/jpeg;base64,/);
  });

  it("returns undefined (no throw) on a non-ok response", async () => {
    const img = image("img3");
    const onDropped = vi.fn();
    const fetchImpl = vi.fn(async () => ({ ok: false, status: 404, blob: async () => new Blob() }));

    const url = await resolveImageBytes(img, {
      database: db,
      fetchImpl: fetchImpl as unknown as typeof fetch,
      tokenUrl: async () => "http://pb/x",
      onDropped,
    });

    expect(url).toBeUndefined();
    expect(onDropped).toHaveBeenCalledTimes(1);
  });

  it("returns undefined (no throw) when fetch itself rejects (offline)", async () => {
    const img = image("img4");
    const fetchImpl = vi.fn(async () => {
      throw new Error("network down");
    });
    const url = await resolveImageBytes(img, {
      database: db,
      fetchImpl: fetchImpl as unknown as typeof fetch,
      tokenUrl: async () => "http://pb/x",
    });
    expect(url).toBeUndefined();
  });

  it("retries ONCE with a fresh token URL on a 401, then succeeds", async () => {
    const img = image("img5");
    let call = 0;
    const tokenUrl = vi.fn(async () => `http://pb/x?token=t${call}`);
    const fetchImpl = vi.fn(async () => {
      call += 1;
      if (call === 1) {
        return { ok: false, status: 401, blob: async () => new Blob() };
      }
      return { ok: true, status: 200, blob: async () => new Blob(["B"], { type: "image/jpeg" }) };
    });

    const url = await resolveImageBytes(img, {
      database: db,
      fetchImpl: fetchImpl as unknown as typeof fetch,
      tokenUrl,
    });

    expect(fetchImpl).toHaveBeenCalledTimes(2);
    expect(tokenUrl).toHaveBeenCalledTimes(2); // re-minted after the 401
    expect(url).toMatch(/^data:image\/jpeg;base64,/);
  });

  it("rejects a 200 NON-image body (e.g. HTML error page) as undefined", async () => {
    const img = image("img6");
    const fetchImpl = vi.fn(async () => ({
      ok: true,
      status: 200,
      blob: async () => new Blob(["<html>nope</html>"], { type: "text/html" }),
    }));
    const url = await resolveImageBytes(img, {
      database: db,
      fetchImpl: fetchImpl as unknown as typeof fetch,
      tokenUrl: async () => "http://pb/x",
    });
    expect(url).toBeUndefined();
  });
});
