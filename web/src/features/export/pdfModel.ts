/**
 * Pure deck → PDF-model mapping for the web PDF export (M6).
 *
 * This module is INTENTIONALLY pure: no React, no Dexie, no fetch, no
 * `@react-pdf/renderer`. It is the primary unit-test target for the export
 * feature's correctness (soft-delete filtering, position ordering, empty-field
 * omission, shoot-date formatting). The browser orchestrator
 * (`exportDeckPdf.ts`) feeds it rows already read from Dexie via
 * `liveDeck`/`liveCards`/`liveCardImages`.
 *
 * Ordering contract (adversarial review fix #4 — single source of ordering):
 *  - CARDS are sorted here by `position` ascending. The orchestrator passes the
 *    raw `liveCards` result (already position-sorted), but we re-sort defensively
 *    so a shuffled caller (and the unit tests) still get deterministic output.
 *  - IMAGES are NOT re-sorted: `liveCardImages` is the single source of image
 *    ordering, and `imagesByCard` is expected to already be position-ordered.
 *    We preserve that order to avoid the "ordering lives in two places" divergence
 *    the review called out.
 *
 * The model retains the full {@link CardImage} objects (not just ids) so the
 * injectable image resolver (`imageResolver.ts`) can compute the stable
 * `blobKey` and mint a token URL from them — the resolver needs the record, not
 * just an id.
 */
import { type Card, type CardImage, type Deck, isSoftDeleted } from "@/lib/types";

/** Label shown for a card whose title is blank/whitespace. */
export const UNTITLED_CARD = "Untitled card";

/** Label shown on the cover when a deck has no (parseable) shoot date. */
export const UNDATED_LABEL = "Undated";

/** One omitted-when-empty field row on a card page. */
export interface PdfFieldRow {
  /** Human label, e.g. "Time", "Subjects", "Direction", "Notes". */
  label: string;
  /** Trimmed, non-empty value (empty values are omitted, never emitted). */
  value: string;
}

/** A single card as it appears in the PDF (one page per card). */
export interface PdfCardModel {
  /** Source card id (stable key for the React-PDF list). */
  id: string;
  /** Card title, falling back to {@link UNTITLED_CARD} when blank. */
  title: string;
  /** Populated optional fields only, in display order; empties omitted. */
  fields: PdfFieldRow[];
  /**
   * The card's images in display order (preserved from `liveCardImages`, not
   * re-sorted). Carries the full {@link CardImage} so the resolver can compute
   * the cache key + token URL.
   */
  images: CardImage[];
  /** Ordered image ids (mirrors {@link images}); convenient for layout/tests. */
  imageIds: string[];
}

/** The whole deck as it appears in the PDF. */
export interface PdfDeckModel {
  /** Deck name (passed through verbatim; decks require a non-empty name). */
  name: string;
  /** Cover-page shoot-date label, e.g. "Sat, Jun 7, 2026" or {@link UNDATED_LABEL}. */
  shootDateLabel: string;
  /** Number of non-deleted cards (== `cards.length`). */
  cardCount: number;
  /** Non-deleted cards in position order, one page each. */
  cards: PdfCardModel[];
}

/**
 * Format an ISO shoot date for the cover page. Mirrors `DeckCard.formatShootDate`
 * (same locale options) but returns {@link UNDATED_LABEL} — not `null` — for an
 * empty/unparseable value, since the PDF cover always shows a string.
 */
export function formatShootDate(shootDate: string): string {
  if (typeof shootDate !== "string" || shootDate.trim() === "") {
    return UNDATED_LABEL;
  }
  const ms = Date.parse(shootDate);
  if (Number.isNaN(ms)) {
    return UNDATED_LABEL;
  }
  return new Date(ms).toLocaleDateString(undefined, {
    weekday: "short",
    year: "numeric",
    month: "short",
    day: "numeric",
  });
}

/** Build the omitted-when-empty field rows for one card (in display order). */
function buildFields(card: Card): PdfFieldRow[] {
  const candidates: PdfFieldRow[] = [
    { label: "Time", value: card.time_slot },
    { label: "Subjects", value: card.subjects },
    { label: "Direction", value: card.direction },
    { label: "Notes", value: card.notes },
  ];
  return candidates
    .map((f) => ({ label: f.label, value: typeof f.value === "string" ? f.value.trim() : "" }))
    .filter((f) => f.value !== "");
}

/**
 * Map a deck + its cards + per-card images into the pure PDF model.
 *
 * @param deck         the deck (its `name` and `shoot_date` drive the cover).
 * @param cards        the deck's cards. Soft-deleted cards are excluded and the
 *                     rest are sorted by `position` ascending.
 * @param imagesByCard per-card images, expected already position-ordered (from
 *                     `liveCardImages`); the order is PRESERVED, not re-sorted.
 */
export function buildPdfModel(
  deck: Pick<Deck, "name" | "shoot_date">,
  cards: Card[],
  imagesByCard: Map<string, CardImage[]>,
): PdfDeckModel {
  const liveCards = cards
    .filter((c) => !isSoftDeleted(c))
    .slice()
    .sort((a, b) => a.position - b.position);

  const cardModels: PdfCardModel[] = liveCards.map((card) => {
    const images = imagesByCard.get(card.id) ?? [];
    return {
      id: card.id,
      title: card.title.trim() || UNTITLED_CARD,
      fields: buildFields(card),
      images,
      imageIds: images.map((i) => i.id),
    };
  });

  return {
    name: deck.name,
    shootDateLabel: formatShootDate(deck.shoot_date),
    cardCount: cardModels.length,
    cards: cardModels,
  };
}

/** All {@link CardImage} records across the model, in page/display order. */
export function allModelImages(model: PdfDeckModel): CardImage[] {
  return model.cards.flatMap((c) => c.images);
}
