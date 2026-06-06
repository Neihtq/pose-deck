import { Blob as NodeBlob } from "node:buffer";

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import {
  JPEG_QUALITY,
  MAX_LONG_EDGE,
  OUTPUT_MIME,
  compressImage,
  fitWithinLongEdge,
  sha256Hex,
} from "../compress";

/**
 * Capture of the args the compression pipeline passes to the canvas encode so
 * tests can assert on quality / dimension wiring without a real renderer.
 */
interface EncodeCapture {
  width: number;
  height: number;
  drawArgs: unknown[];
  blobType?: string;
  blobQuality?: number;
}

describe("fitWithinLongEdge", () => {
  it("leaves images at or below the long edge unchanged", () => {
    expect(fitWithinLongEdge(800, 600)).toEqual({ width: 800, height: 600 });
    expect(fitWithinLongEdge(1080, 500)).toEqual({ width: 1080, height: 500 });
  });

  it("scales a landscape image so the long edge becomes the max", () => {
    const out = fitWithinLongEdge(2160, 1080);
    expect(out).toEqual({ width: MAX_LONG_EDGE, height: 540 });
  });

  it("scales a portrait image so the long edge becomes the max", () => {
    const out = fitWithinLongEdge(1080, 2160);
    expect(out).toEqual({ width: 540, height: MAX_LONG_EDGE });
  });

  it("never produces a zero dimension", () => {
    const out = fitWithinLongEdge(10000, 1);
    expect(out.width).toBe(MAX_LONG_EDGE);
    expect(out.height).toBeGreaterThanOrEqual(1);
  });
});

describe("compressImage param wiring", () => {
  const originalCreateImageBitmap = globalThis.createImageBitmap;
  const originalOffscreen = globalThis.OffscreenCanvas;
  let capture: EncodeCapture;

  beforeEach(() => {
    capture = { width: 0, height: 0, drawArgs: [] };

    // Source bitmap is 2160x1080 — should be scaled to 1080x540.
    const bitmap = {
      width: 2160,
      height: 1080,
      close: vi.fn(),
    } as unknown as ImageBitmap;

    vi.stubGlobal(
      "createImageBitmap",
      vi.fn(async () => bitmap),
    );

    // Mock OffscreenCanvas: record the size and the convertToBlob params.
    class MockOffscreenCanvas {
      width: number;
      height: number;
      constructor(width: number, height: number) {
        this.width = width;
        this.height = height;
        capture.width = width;
        capture.height = height;
      }
      getContext() {
        return {
          drawImage: (...args: unknown[]) => {
            capture.drawArgs = args;
          },
        };
      }
      async convertToBlob(opts: { type: string; quality: number }) {
        capture.blobType = opts.type;
        capture.blobQuality = opts.quality;
        return new Blob([new Uint8Array([1, 2, 3])], { type: opts.type });
      }
    }
    vi.stubGlobal("OffscreenCanvas", MockOffscreenCanvas);
  });

  afterEach(() => {
    vi.unstubAllGlobals();
    globalThis.createImageBitmap = originalCreateImageBitmap;
    globalThis.OffscreenCanvas = originalOffscreen;
    vi.restoreAllMocks();
  });

  it("encodes JPEG at quality 0.8 and the clamped 1080px long edge", async () => {
    const src = new Blob([new Uint8Array([9, 9, 9])], { type: "image/png" });
    const out = await compressImage(src);

    // Canvas sized to the scaled dimensions.
    expect(capture.width).toBe(MAX_LONG_EDGE);
    expect(capture.height).toBe(540);

    // drawImage targets the same scaled box at the origin.
    expect(capture.drawArgs.slice(1)).toEqual([0, 0, MAX_LONG_EDGE, 540]);

    // Encode params wired through the module constants.
    expect(capture.blobType).toBe(OUTPUT_MIME);
    expect(capture.blobQuality).toBe(JPEG_QUALITY);

    // Output is a JPEG blob.
    expect(out.type).toBe(OUTPUT_MIME);
  });

  it("throws when createImageBitmap is unavailable", async () => {
    vi.stubGlobal("createImageBitmap", undefined);
    await expect(compressImage(new Blob(["x"]))).rejects.toThrow(
      /createImageBitmap/,
    );
  });
});

describe("sha256Hex", () => {
  // jsdom's Blob does not implement byte reading (no `arrayBuffer`, and it is
  // not interoperable with Node's `Response`). Use Node's spec-compliant Blob —
  // which has working `arrayBuffer`, just like real browsers — so the digest
  // reads the actual bytes. `sha256Hex` itself is environment-agnostic.
  const makeBlob = (bytes?: Uint8Array): Blob =>
    (bytes === undefined
      ? new NodeBlob([])
      : new NodeBlob([bytes])) as unknown as Blob;

  it("is deterministic for identical bytes", async () => {
    const a = makeBlob(new Uint8Array([1, 2, 3, 4]));
    const b = makeBlob(new Uint8Array([1, 2, 3, 4]));
    const ha = await sha256Hex(a);
    const hb = await sha256Hex(b);
    expect(ha).toBe(hb);
    // Lowercase 64-char hex (256 bits).
    expect(ha).toMatch(/^[0-9a-f]{64}$/);
  });

  it("differs for different bytes", async () => {
    const ha = await sha256Hex(makeBlob(new Uint8Array([1, 2, 3])));
    const hb = await sha256Hex(makeBlob(new Uint8Array([1, 2, 4])));
    expect(ha).not.toBe(hb);
  });

  it("matches the known SHA-256 of the empty input", async () => {
    const h = await sha256Hex(makeBlob());
    expect(h).toBe(
      "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    );
  });
});
