/**
 * Injectable image-byte resolution for the PDF export (M6).
 *
 * `@react-pdf/renderer`'s `<Image src>` accepts a base64 DATA URL (object URLs
 * are transient and unreliable inside the renderer), so the export resolves
 * every card image to a data URL string BEFORE the synchronous React-PDF render.
 *
 * Strategy — full-resolution, cache-first, network-fallback, FAIL-SOFT:
 *  1. compute the stable, token-stripped key `blobKey(image, image.file)` with NO
 *     thumb variant (print wants full-res — and `pinDeck` caches the full-res
 *     file under exactly this key, so a pinned deck is a zero-network hit);
 *  2. on a Dexie `image_blobs` hit, read the bytes with no network and no token;
 *  3. on a miss, mint a short-lived protected token URL (reusing
 *     `imageApi.imageDisplayUrl` → `getFileToken`'s cache/refresh) and `fetch()`
 *     the bytes;
 *  4. convert the Blob to a base64 data URL (`FileReader.readAsDataURL`).
 *
 * Fail-soft contract (adversarial review): the default resolver NEVER throws.
 * Any failure (offline, `!res.ok`, expired token even after a retry, a non-image
 * body, a decode error) resolves to `undefined`, which the Document treats as
 * "skip this image / show a placeholder". This module is injectable
 * (`ImageBytesResolver`) so unit tests pass canned data URLs and exercise no
 * Dexie / fetch / FileReader.
 *
 * Adversarial fixes folded in:
 *  - #2 token expiry: on a `401`/`403` network response, clear + re-mint the file
 *    token and retry the fetch ONCE before giving up. A per-run dropped-image
 *    COUNT is surfaced so the orchestrator can warn instead of silently omitting.
 *  - #6 memory: downscale to a print-reasonable longest-edge before encoding when
 *    a canvas is available (browser); a no-op in node/tests where canvas is
 *    absent, so the embedded bytes stay bounded on phones/tablets.
 *  - #7 bad body: validate the fetched `Content-Type` is `image/*` before
 *    building a data URL, so a 200 HTML error page can't smuggle a non-image
 *    string into the renderer (which would throw mid-render).
 */
import { type PoseDeckDB, db as defaultDb } from "@/lib/db";
import { blobKey } from "@/lib/offlineKeys";
import { imageDisplayUrl } from "@/features/images/imageApi";
import { clearFileToken } from "@/lib/pocketbase";
import type { CardImage } from "@/lib/types";

/**
 * Resolve one card image to a base64 data URL, or `undefined` if it cannot be
 * resolved. MUST NOT throw — callers rely on the fail-soft guarantee.
 */
export type ImageBytesResolver = (
  image: CardImage,
) => Promise<string | undefined>;

/** Longest-edge cap for embedded print images (≈1500px ≈ 150dpi at 10in). */
export const PRINT_MAX_EDGE = 1500;

/** Mint a protected token URL for an image. Injectable for tests. */
export type TokenUrlResolver = (image: CardImage) => Promise<string>;

/** Dependencies for {@link resolveImageBytes}, injectable for tests. */
export interface ResolveImageBytesDeps {
  /** Dexie handle (defaults to the shared singleton). */
  database?: PoseDeckDB;
  /** `fetch` implementation (defaults to the global). */
  fetchImpl?: typeof fetch;
  /** Token-URL minter (defaults to `imageApi.imageDisplayUrl`, full-res). */
  tokenUrl?: TokenUrlResolver;
  /**
   * Count sink for images that could not be resolved (so the orchestrator can
   * warn). Incremented once per dropped image; optional.
   */
  onDropped?: () => void;
}

/** Read a Blob as a base64 data URL. Rejects on a FileReader error. */
function blobToDataUrl(blob: Blob): Promise<string> {
  return new Promise<string>((resolve, reject) => {
    const reader = new FileReader();
    reader.onerror = () => reject(reader.error ?? new Error("read failed"));
    reader.onload = () => resolve(String(reader.result));
    reader.readAsDataURL(blob);
  });
}

/**
 * Downscale an image Blob so its longest edge is ≤ {@link PRINT_MAX_EDGE},
 * re-encoding as JPEG to bound the embedded byte size (adversarial fix #6).
 * Best-effort: if no DOM canvas / `createImageBitmap` is available (node, tests)
 * or anything fails, the ORIGINAL blob is returned unchanged.
 */
async function downscaleForPrint(blob: Blob): Promise<Blob> {
  // Guard for the browser-only APIs; absent in node/jsdom test envs.
  if (
    typeof document === "undefined" ||
    typeof createImageBitmap !== "function"
  ) {
    return blob;
  }
  try {
    const bitmap = await createImageBitmap(blob);
    const longest = Math.max(bitmap.width, bitmap.height);
    if (longest <= PRINT_MAX_EDGE) {
      bitmap.close?.();
      return blob;
    }
    const scale = PRINT_MAX_EDGE / longest;
    const w = Math.round(bitmap.width * scale);
    const h = Math.round(bitmap.height * scale);
    const canvas = document.createElement("canvas");
    canvas.width = w;
    canvas.height = h;
    const ctx = canvas.getContext("2d");
    if (!ctx) {
      bitmap.close?.();
      return blob;
    }
    ctx.drawImage(bitmap, 0, 0, w, h);
    bitmap.close?.();
    const out = await new Promise<Blob | null>((resolve) =>
      canvas.toBlob((b) => resolve(b), "image/jpeg", 0.82),
    );
    return out ?? blob;
  } catch {
    return blob;
  }
}

/** Is `blob` something the renderer can decode as an image? */
function isImageBlob(blob: Blob): boolean {
  // PocketBase serves the original content-type; a 200 HTML error page would be
  // text/html. An empty type is tolerated (some fetch polyfills omit it).
  return blob.type === "" || blob.type.startsWith("image/");
}

const defaultTokenUrl: TokenUrlResolver = (image) => imageDisplayUrl(image);

/**
 * Default browser resolver: cache-first (Dexie full-res), network fallback with
 * a one-shot token refresh on 401/403, content-type validation, print downscale,
 * then data-URL encode. NEVER throws — returns `undefined` on any failure and
 * (optionally) increments the dropped-image counter.
 */
export async function resolveImageBytes(
  image: CardImage,
  deps: ResolveImageBytesDeps = {},
): Promise<string | undefined> {
  const {
    database = defaultDb,
    fetchImpl = fetch,
    tokenUrl = defaultTokenUrl,
    onDropped,
  } = deps;
  try {
    // (1)+(2) Cache-first: full-res, token-stripped key. A pin hit = zero network.
    const key = blobKey(image, image.file);
    const cached = await database.image_blobs.get(key);
    if (cached) {
      const scaled = await downscaleForPrint(cached.blob);
      return await blobToDataUrl(scaled);
    }

    // (3) Network fallback through the protected token URL, with a single retry
    // on an auth failure after refreshing the cached file token.
    const doFetch = async (): Promise<Response> => {
      const url = await tokenUrl(image);
      return fetchImpl(url);
    };
    let res = await doFetch();
    if (!res.ok && (res.status === 401 || res.status === 403)) {
      clearFileToken();
      res = await doFetch();
    }
    if (!res.ok) {
      onDropped?.();
      return undefined;
    }
    const blob = await res.blob();
    if (!isImageBlob(blob)) {
      onDropped?.();
      return undefined;
    }
    const scaled = await downscaleForPrint(blob);
    // (4) data URL — react-pdf <Image src> wants this, not an object URL.
    return await blobToDataUrl(scaled);
  } catch {
    // Fail-soft: any error (offline, decode, FileReader) drops this one image.
    onDropped?.();
    return undefined;
  }
}

/** Outcome of resolving all of a model's images. */
export interface ResolvedImages {
  /** image id → data URL (or `undefined` when it could not be resolved). */
  sources: Map<string, string | undefined>;
  /** How many images could not be resolved (for a "N images unavailable" warning). */
  dropped: number;
}

/**
 * Resolve EVERY image in the model to a data URL (or `undefined`) using the
 * injected resolver, with bounded concurrency to shorten the wall-clock and the
 * token-expiry window (adversarial fix #2). Pure orchestration over the resolver
 * — unit-testable with a fake resolver, no Dexie/fetch needed.
 *
 * The resolver is invoked exactly once per image id (de-duplicated, so a card
 * reusing an image id does not double-fetch). `dropped` counts `undefined`
 * results so the caller can warn.
 */
export async function resolveAllImages(
  images: CardImage[],
  resolver: ImageBytesResolver,
  concurrency = 4,
): Promise<ResolvedImages> {
  // De-dupe by id so each distinct image resolves once.
  const unique = new Map<string, CardImage>();
  for (const img of images) {
    if (!unique.has(img.id)) {
      unique.set(img.id, img);
    }
  }
  const entries = [...unique.values()];
  const sources = new Map<string, string | undefined>();
  let dropped = 0;

  let cursor = 0;
  const limit = Math.max(1, concurrency);
  const worker = async (): Promise<void> => {
    while (cursor < entries.length) {
      const img = entries[cursor++];
      const url = await resolver(img);
      sources.set(img.id, url);
      if (url === undefined) {
        dropped += 1;
      }
    }
  };
  await Promise.all(
    Array.from({ length: Math.min(limit, entries.length) }, () => worker()),
  );

  return { sources, dropped };
}
