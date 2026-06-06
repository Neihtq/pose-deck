/**
 * Client-side image pipeline (ARCHITECTURE.md §5).
 *
 * Compresses picked / pasted images to a 1080px long edge and re-encodes as
 * JPEG quality 0.8 before upload, then discards the original. Also computes a
 * SHA-256 content hash for dedup-on-upload.
 *
 * The encode prefers `OffscreenCanvas` (works off the main thread / in workers)
 * but falls back to an `HTMLCanvasElement` for environments that lack it.
 */

/** Max length of the longest image edge after compression (px). */
export const MAX_LONG_EDGE = 1080;

/** JPEG quality used when re-encoding (0..1). */
export const JPEG_QUALITY = 0.8;

/** Output MIME type for compressed images. */
export const OUTPUT_MIME = "image/jpeg";

/** Does the current environment expose a usable `OffscreenCanvas`? */
function hasOffscreenCanvas(): boolean {
  return (
    typeof OffscreenCanvas !== "undefined" &&
    typeof OffscreenCanvas.prototype.getContext === "function"
  );
}

/** Compute the target dimensions, clamping the long edge to {@link MAX_LONG_EDGE}. */
export function fitWithinLongEdge(
  width: number,
  height: number,
  maxLongEdge: number = MAX_LONG_EDGE,
): { width: number; height: number } {
  const longEdge = Math.max(width, height);
  if (longEdge <= maxLongEdge || longEdge === 0) {
    return { width, height };
  }
  const scale = maxLongEdge / longEdge;
  return {
    width: Math.max(1, Math.round(width * scale)),
    height: Math.max(1, Math.round(height * scale)),
  };
}

/** Encode an `OffscreenCanvas` to a JPEG blob. */
async function encodeOffscreen(
  bitmap: ImageBitmap,
  width: number,
  height: number,
  quality: number,
): Promise<Blob> {
  const canvas = new OffscreenCanvas(width, height);
  const ctx = canvas.getContext("2d");
  if (!ctx) {
    throw new Error("Failed to get 2D context from OffscreenCanvas");
  }
  ctx.drawImage(bitmap, 0, 0, width, height);
  return canvas.convertToBlob({ type: OUTPUT_MIME, quality });
}

/** Encode an `HTMLCanvasElement` to a JPEG blob. */
async function encodeHtmlCanvas(
  bitmap: ImageBitmap,
  width: number,
  height: number,
  quality: number,
): Promise<Blob> {
  const canvas = document.createElement("canvas");
  canvas.width = width;
  canvas.height = height;
  const ctx = canvas.getContext("2d");
  if (!ctx) {
    throw new Error("Failed to get 2D context from canvas");
  }
  ctx.drawImage(bitmap, 0, 0, width, height);
  return new Promise<Blob>((resolve, reject) => {
    canvas.toBlob(
      (blob) => {
        if (blob) {
          resolve(blob);
        } else {
          reject(new Error("canvas.toBlob produced no blob"));
        }
      },
      OUTPUT_MIME,
      quality,
    );
  });
}

/**
 * Resize the given image to a {@link MAX_LONG_EDGE}px long edge and re-encode it
 * as JPEG at {@link JPEG_QUALITY}. Returns the compressed blob; the original is
 * not retained.
 *
 * @param file the source image blob (from a file input, drag-drop, or paste).
 */
export async function compressImage(file: Blob): Promise<Blob> {
  if (typeof createImageBitmap !== "function") {
    throw new Error("createImageBitmap is not available in this environment");
  }

  const bitmap = await createImageBitmap(file);
  try {
    const { width, height } = fitWithinLongEdge(bitmap.width, bitmap.height);
    if (hasOffscreenCanvas()) {
      return await encodeOffscreen(bitmap, width, height, JPEG_QUALITY);
    }
    return await encodeHtmlCanvas(bitmap, width, height, JPEG_QUALITY);
  } finally {
    // Release decoded image memory promptly.
    bitmap.close?.();
  }
}

/** Lowercase hex encoding of a byte array. */
function toHex(bytes: Uint8Array): string {
  let out = "";
  for (let i = 0; i < bytes.length; i++) {
    out += bytes[i].toString(16).padStart(2, "0");
  }
  return out;
}

/**
 * Compute the SHA-256 of a blob's bytes, returned as a lowercase hex string.
 * Used for dedup-on-upload (ARCHITECTURE.md §5 step 3). Deterministic: the same
 * bytes always yield the same digest.
 */
export async function sha256Hex(blob: Blob): Promise<string> {
  // Prefer Blob.arrayBuffer (all browsers); fall back via Response for
  // environments whose Blob lacks it (e.g. jsdom under test).
  const buffer =
    typeof blob.arrayBuffer === "function"
      ? await blob.arrayBuffer()
      : await new Response(blob).arrayBuffer();
  const digest = await crypto.subtle.digest("SHA-256", buffer);
  return toHex(new Uint8Array(digest));
}
