/**
 * Unit tests for offline image cache keys (M3 STEP 6, invariant #5).
 *
 * The cache key MUST strip the volatile `?token=` (so a refreshed token never
 * thrashes the cache) and MUST preserve `thumb` (so full-res and thumbnail
 * bytes cache under distinct keys). These are the load-bearing properties of
 * invariant #5; test them thoroughly.
 */
import { describe, expect, it } from "vitest";

import { blobKey, blobKeyFromUrl, type FileRef } from "../offlineKeys";

const REC: FileRef = {
  id: "rec123",
  collectionName: "card_images",
  collectionId: "pbc_999",
};

describe("blobKey", () => {
  it("builds collection/record/filename for the full-res file", () => {
    expect(blobKey(REC, "photo.jpg")).toBe("card_images/rec123/photo.jpg");
  });

  it("appends a thumb suffix that is preserved in the key", () => {
    expect(blobKey(REC, "photo.jpg", { thumb: "200x200" })).toBe(
      "card_images/rec123/photo.jpg@thumb=200x200",
    );
  });

  it("gives full-res and each thumb variant DISTINCT keys", () => {
    const full = blobKey(REC, "photo.jpg");
    const t200 = blobKey(REC, "photo.jpg", { thumb: "200x200" });
    const t300 = blobKey(REC, "photo.jpg", { thumb: "300x300" });
    expect(new Set([full, t200, t300]).size).toBe(3);
  });

  it("is independent of the token (the key never contains a token)", () => {
    // The builder takes only the record + filename + thumb, never a URL, so a
    // token can't leak into the key by construction.
    const a = blobKey(REC, "photo.jpg", { thumb: "200x200" });
    const b = blobKey(REC, "photo.jpg", { thumb: "200x200" });
    expect(a).toBe(b);
    expect(a).not.toContain("token");
  });

  it("falls back to collectionId then a constant when name is absent", () => {
    expect(blobKey({ id: "r" }, "p.jpg")).toBe("card_images/r/p.jpg");
    expect(blobKey({ id: "r", collectionId: "pbc_1" }, "p.jpg")).toBe(
      "pbc_1/r/p.jpg",
    );
  });
});

describe("blobKeyFromUrl", () => {
  const base = "https://api.example.com/api/files/card_images/rec123/photo.jpg";

  it("strips the token and yields the same key as blobKey (full res)", () => {
    expect(blobKeyFromUrl(`${base}?token=abc.def.ghi`)).toBe(
      blobKey(REC, "photo.jpg"),
    );
  });

  it("preserves thumb and strips token together", () => {
    expect(blobKeyFromUrl(`${base}?thumb=200x200&token=abc`)).toBe(
      blobKey(REC, "photo.jpg", { thumb: "200x200" }),
    );
  });

  it("yields the SAME key for two different tokens (no thrash)", () => {
    const k1 = blobKeyFromUrl(`${base}?thumb=300x300&token=stale`);
    const k2 = blobKeyFromUrl(`${base}?thumb=300x300&token=fresh`);
    expect(k1).toBe(k2);
  });

  it("returns null for a non-file URL", () => {
    expect(blobKeyFromUrl("https://api.example.com/api/collections/x")).toBeNull();
    expect(blobKeyFromUrl("not a url")).toBeNull();
  });
});
