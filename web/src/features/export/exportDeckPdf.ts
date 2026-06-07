/**
 * Browser-only orchestrator for the deck PDF export (M6).
 *
 * Flow (all async resolution happens BEFORE the synchronous React-PDF render):
 *  1. read the deck + its non-deleted cards + each card's images from Dexie via
 *     the local-first live queries (`liveDeck`/`liveCards`/`liveCardImages`);
 *  2. build the pure {@link PdfDeckModel} and a `imagesByCard` map (the SAME
 *     `liveCardImages` result feeds both the model and the resolver — single
 *     source of ordering, adversarial fix #4);
 *  3. resolve every image to a data URL up front (`resolveAllImages`), counting
 *     any that drop out (fix #2);
 *  4. render `pdf(<PdfDocument/>).toBlob()` (wrapped so a render-time image error
 *     can't crash the whole export — fix #7);
 *  5. trigger a download named after the deck, revoking the object URL on a safe
 *     delay (fix #5).
 *
 * This module imports `@react-pdf/renderer` and is reached ONLY via a dynamic
 * `import()` from the click handler (adversarial fix #9), so the heavy renderer
 * is code-split out of the initial app chunk.
 */
import { pdf } from "@react-pdf/renderer";

import { type PoseDeckDB, db as defaultDb } from "@/lib/db";
import { liveCardImages, liveCards, liveDeck } from "@/lib/localStore";
import type { CardImage } from "@/lib/types";

import { PdfDocument } from "./PdfDocument";
import { buildPdfModel } from "./pdfModel";
import {
  type ImageBytesResolver,
  resolveAllImages,
  resolveImageBytes,
} from "./imageResolver";

/** Thrown when the deck to export is missing or soft-deleted. */
export class DeckNotFoundError extends Error {
  constructor(deckId: string) {
    super(`Deck ${deckId} not found`);
    this.name = "DeckNotFoundError";
  }
}

/** Options for {@link exportDeckPdf}, injectable for tests. */
export interface ExportDeckPdfOptions {
  /** Dexie handle (defaults to the shared singleton). */
  db?: PoseDeckDB;
  /** Image-byte resolver (defaults to the cache-first/network resolver). */
  resolver?: ImageBytesResolver;
  /** Override the generated file name (defaults to `<deck name>.pdf`). */
  fileName?: string;
}

/** Result of an export: the file name written and how many images dropped out. */
export interface ExportResult {
  fileName: string;
  /** Count of images that could not be resolved (omitted from the PDF). */
  droppedImages: number;
}

/** Sanitize a deck name into a safe `.pdf` file name. */
export function pdfFileName(deckName: string): string {
  const base = deckName.trim().replace(/[\\/:*?"<>|]+/g, "-").replace(/\s+/g, " ");
  const safe = base === "" ? "deck" : base;
  return `${safe}.pdf`;
}

/**
 * FileSaver-style download trigger. Appends a hidden anchor to the DOM, clicks
 * it, removes it, then revokes the object URL on a SAFE delay.
 *
 * The revoke delay matters (adversarial fix #5): revoking on a microtask /
 * `setTimeout(0)` can cancel the download before the browser captures the blob
 * (notably older Safari / iOS WebKit — a plausible client for the
 * planner-handoff use case). We wait 60s, by which point any browser has
 * committed the download.
 */
export function triggerDownload(blob: Blob, fileName: string): void {
  const url = URL.createObjectURL(blob);
  const anchor = document.createElement("a");
  anchor.href = url;
  anchor.download = fileName;
  anchor.rel = "noopener";
  anchor.style.display = "none";
  document.body.appendChild(anchor);
  anchor.click();
  document.body.removeChild(anchor);
  // Revoke late so slow/older browsers (Safari/iOS) finish capturing the blob.
  setTimeout(() => URL.revokeObjectURL(url), 60_000);
}

/**
 * Export `deckId` to a downloaded PDF. Reads everything from Dexie (local-first,
 * so a pinned deck exports offline), resolves images, renders, and downloads.
 *
 * @returns the file name and the count of images that could not be embedded.
 * @throws  {@link DeckNotFoundError} if the deck is missing/soft-deleted. All
 *          per-image failures are fail-soft (counted in `droppedImages`), and a
 *          render-time image error is downgraded to a dropped image rather than
 *          failing the whole export.
 */
export async function exportDeckPdf(
  deckId: string,
  options: ExportDeckPdfOptions = {},
): Promise<ExportResult> {
  const { db = defaultDb, resolver = resolveImageBytes, fileName } = options;

  const deck = await liveDeck(db, deckId);
  if (!deck) {
    throw new DeckNotFoundError(deckId);
  }
  const cards = await liveCards(db, deckId);

  // Per-card images: the SAME list feeds the model AND the resolver, so image
  // ordering has one source (liveCardImages). Build the map and a flat list.
  const imagesByCard = new Map<string, CardImage[]>();
  const allImages: CardImage[] = [];
  for (const card of cards) {
    const imgs = await liveCardImages(db, card.id);
    imagesByCard.set(card.id, imgs);
    allImages.push(...imgs);
  }

  const model = buildPdfModel(deck, cards, imagesByCard);
  const { sources, dropped } = await resolveAllImages(allImages, resolver);

  const name = fileName ?? pdfFileName(deck.name);

  // Render to a Blob. Wrap so a renderer-side image decode error (a 200 body
  // that is technically a data URL but not a decodable image) cannot crash the
  // whole export — fix #7. The component already skips `undefined` sources; this
  // is defense-in-depth for a malformed-but-present source.
  let blob: Blob;
  try {
    blob = await pdf(PdfDocument({ model, imageSources: sources })).toBlob();
  } catch {
    // Retry once with ALL image sources dropped so the text-only PDF still
    // exports rather than failing the user's action entirely.
    const empty = new Map<string, string | undefined>();
    blob = await pdf(PdfDocument({ model, imageSources: empty })).toBlob();
    triggerDownload(blob, name);
    return { fileName: name, droppedImages: model.cards.reduce((n, c) => n + c.imageIds.length, 0) };
  }

  triggerDownload(blob, name);
  return { fileName: name, droppedImages: dropped };
}
