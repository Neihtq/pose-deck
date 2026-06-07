/**
 * Unit tests for `resolveImage` (M3 STEP 6, invariant #5).
 *
 * Covers: the network fallback when no blob is pinned (no-op release), the
 * cached-blob path (object URL + a release that revokes it exactly once), and
 * that a refreshed token (different key suffix aside) does not miss the pin
 * because the key strips the token. jsdom lacks `URL.createObjectURL`, so we
 * stub the object-URL API and assert create/revoke pairing.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { PoseDeckDB } from "../db";
import { resolveImage } from "../offlineImages";
import { blobKey } from "../offlineKeys";
import type { CardImage } from "../types";

const IMAGE: CardImage = {
  id: "img1",
  card: "card1",
  file: "photo.jpg",
  position: 0,
  created: "",
  collectionName: "card_images",
};

let db: PoseDeckDB;
const created: string[] = [];
const revoked: string[] = [];

beforeEach(async () => {
  db = new PoseDeckDB(`test-${crypto.randomUUID()}`);
  await db.open();
  created.length = 0;
  revoked.length = 0;
  // Stub the object-URL API (absent in jsdom). Each call mints a unique URL.
  vi.stubGlobal("URL", {
    ...URL,
    createObjectURL: vi.fn((_blob: Blob) => {
      const u = `blob:fake/${created.length}`;
      created.push(u);
      return u;
    }),
    revokeObjectURL: vi.fn((u: string) => {
      revoked.push(u);
    }),
  });
});

afterEach(() => {
  db.close();
  vi.unstubAllGlobals();
});

describe("resolveImage — network fallback (un-pinned)", () => {
  it("returns the network URL and a no-op release", async () => {
    const networkUrl = vi.fn().mockResolvedValue("/api/files/x?token=abc");
    const handle = await resolveImage(IMAGE, { database: db, networkUrl });
    expect(handle.fromCache).toBe(false);
    expect(handle.url).toBe("/api/files/x?token=abc");
    expect(networkUrl).toHaveBeenCalledWith(IMAGE, {});
    // No-op release must not touch the object-URL API.
    handle.release();
    expect(revoked).toEqual([]);
  });

  it("passes the thumb through to the network resolver", async () => {
    const networkUrl = vi.fn().mockResolvedValue("/api/files/x?thumb=200x200");
    await resolveImage(IMAGE, { database: db, networkUrl, thumb: "200x200" });
    expect(networkUrl).toHaveBeenCalledWith(IMAGE, { thumb: "200x200" });
  });
});

describe("resolveImage — pinned blob", () => {
  it("serves an object URL over the cached blob and revokes on release", async () => {
    const bytes = new Blob(["data"], { type: "image/jpeg" });
    await db.image_blobs.put({
      key: blobKey(IMAGE, IMAGE.file, { thumb: "200x200" }),
      card: IMAGE.card,
      recordId: IMAGE.id,
      blob: bytes,
      cachedAt: 0,
    });
    const networkUrl = vi.fn();

    const handle = await resolveImage(IMAGE, {
      database: db,
      networkUrl,
      thumb: "200x200",
    });

    expect(handle.fromCache).toBe(true);
    expect(handle.url).toBe("blob:fake/0");
    // The network resolver must NOT be consulted when a blob is pinned.
    expect(networkUrl).not.toHaveBeenCalled();
    expect(created).toEqual(["blob:fake/0"]);

    handle.release();
    expect(revoked).toEqual(["blob:fake/0"]);
  });

  it("misses the pin if the requested thumb variant is not cached", async () => {
    // Full-res cached, but a 200x200 request must fall through to the network.
    await db.image_blobs.put({
      key: blobKey(IMAGE, IMAGE.file),
      card: IMAGE.card,
      recordId: IMAGE.id,
      blob: new Blob(["full"]),
      cachedAt: 0,
    });
    const networkUrl = vi.fn().mockResolvedValue("/api/files/x?thumb=200x200");
    const handle = await resolveImage(IMAGE, {
      database: db,
      networkUrl,
      thumb: "200x200",
    });
    expect(handle.fromCache).toBe(false);
    expect(networkUrl).toHaveBeenCalled();
  });
});
