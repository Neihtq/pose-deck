/**
 * Offline unit tests for the image upload hook.
 *
 * The `./compress` and `./imageApi` modules are mocked so no canvas, crypto, or
 * network is involved. These tests focus on the upload orchestration: ordering,
 * the per-card cap, and — the regression of interest — dedup-on-upload
 * (ARCHITECTURE.md §5 step 3), where `sha256Hex` must be invoked to skip blobs
 * whose compressed content matches one already uploaded in the same batch.
 */
import { act, renderHook } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import type { CardImage } from "@/lib/types";

// --- Mock the compress + API modules --------------------------------------

const compressImage = vi.fn();
const sha256Hex = vi.fn();
const listCardImages = vi.fn();
const uploadCardImage = vi.fn();

vi.mock("../compress", () => ({
  compressImage: (blob: Blob) => compressImage(blob),
  sha256Hex: (blob: Blob) => sha256Hex(blob),
}));

vi.mock("../imageApi", async () => {
  const actual =
    await vi.importActual<typeof import("../imageApi")>("../imageApi");
  return {
    ...actual,
    listCardImages: (cardId: string) => listCardImages(cardId),
    uploadCardImage: (cardId: string, blob: Blob, position: number) =>
      uploadCardImage(cardId, blob, position),
  };
});

import { useImageUpload } from "../useImageUpload";

/** Build a CardImage stub for an uploaded record. */
function fakeImage(id: string, position: number): CardImage {
  return {
    id,
    card: "c1",
    position,
    file: `${id}.jpg`,
    created: "2026-06-06T10:00:00.000Z",
    updated: "2026-06-06T10:00:00.000Z",
  } as unknown as CardImage;
}

describe("useImageUpload dedup-on-upload (ARCHITECTURE §5 step 3)", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    listCardImages.mockResolvedValue([]);
    // Each blob "compresses" to a sentinel blob that carries its source label so
    // the fake hasher can map identical sources to identical content hashes.
    compressImage.mockImplementation(
      async (blob: Blob) => blob as unknown as Blob,
    );
    // Hash = the blob's declared type, so two blobs with the same type collide.
    sha256Hex.mockImplementation(async (blob: Blob) => `hash:${blob.type}`);
    let counter = 0;
    uploadCardImage.mockImplementation(async () => {
      counter += 1;
      return fakeImage(`img${counter}`, counter * 1000);
    });
  });

  const blob = (label: string): Blob =>
    new Blob([new Uint8Array([1, 2, 3])], { type: label });

  it("computes a content hash and skips duplicate blobs in a batch", async () => {
    const { result } = renderHook(() => useImageUpload("c1"));

    let created: CardImage[] = [];
    await act(async () => {
      // Three blobs: A, A (duplicate), B. Only A and B should be uploaded.
      created = await result.current.upload([
        blob("image/a"),
        blob("image/a"),
        blob("image/b"),
      ]);
    });

    // sha256Hex must actually be invoked — the pipeline step exists.
    expect(sha256Hex).toHaveBeenCalled();
    // The duplicate is dropped: only two records are uploaded/returned.
    expect(uploadCardImage).toHaveBeenCalledTimes(2);
    expect(created).toHaveLength(2);
  });

  it("uploads all blobs when their content differs", async () => {
    const { result } = renderHook(() => useImageUpload("c1"));

    await act(async () => {
      await result.current.upload([blob("image/a"), blob("image/b")]);
    });

    expect(uploadCardImage).toHaveBeenCalledTimes(2);
  });
});
