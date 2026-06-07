/**
 * Unit tests for the PURE deck → PDF-model mapping (no React-PDF, no Dexie).
 *
 * These pin the mapping contract the rest of the export relies on: soft-deleted
 * cards excluded, position ordering, empty/whitespace optional fields omitted
 * with the right labels for populated ones, title fallback, the cover shoot-date
 * label, image ordering preserved from `liveCardImages`, and the card count.
 */
import { describe, expect, it } from "vitest";

import type { Card, CardImage, Deck } from "@/lib/types";
import {
  UNDATED_LABEL,
  UNTITLED_CARD,
  allModelImages,
  buildPdfModel,
  formatShootDate,
} from "../pdfModel";

function makeDeck(over: Partial<Deck> = {}): Deck {
  return {
    id: "deck1",
    owner: "u1",
    name: "Smith Wedding",
    shoot_date: "",
    client_updated_at: "",
    created: "",
    updated: "",
    deleted_at: "",
    ...over,
  };
}

function makeCard(over: Partial<Card> & { id: string; position: number }): Card {
  return {
    deck: "deck1",
    title: "",
    time_slot: "",
    subjects: "",
    direction: "",
    notes: "",
    client_updated_at: "",
    created: "",
    updated: "",
    deleted_at: "",
    ...over,
  };
}

function makeImage(id: string, card: string, position: number): CardImage {
  return {
    id,
    card,
    position,
    file: `${id}.jpg`,
    created: "",
    collectionName: "card_images",
  };
}

describe("buildPdfModel", () => {
  it("excludes soft-deleted cards from the model and the count", () => {
    const cards = [
      makeCard({ id: "c1", position: 1000, title: "Keep" }),
      makeCard({ id: "c2", position: 2000, title: "Gone", deleted_at: "2026-06-01T00:00:00Z" }),
    ];
    const model = buildPdfModel(makeDeck(), cards, new Map());
    expect(model.cards.map((c) => c.id)).toEqual(["c1"]);
    expect(model.cardCount).toBe(1);
  });

  it("orders cards by position even when the input is shuffled", () => {
    const cards = [
      makeCard({ id: "c3", position: 3000, title: "Third" }),
      makeCard({ id: "c1", position: 1000, title: "First" }),
      makeCard({ id: "c2", position: 2000, title: "Second" }),
    ];
    const model = buildPdfModel(makeDeck(), cards, new Map());
    expect(model.cards.map((c) => c.title)).toEqual(["First", "Second", "Third"]);
  });

  it("omits empty/whitespace optional fields and keeps populated ones with labels", () => {
    const cards = [
      makeCard({
        id: "c1",
        position: 1000,
        title: "Golden hour",
        time_slot: "5:30pm",
        subjects: "   ", // whitespace → omitted
        direction: "",
        notes: "Backlit, veil toss",
      }),
    ];
    const model = buildPdfModel(makeDeck(), cards, new Map());
    expect(model.cards[0].fields).toEqual([
      { label: "Time", value: "5:30pm" },
      { label: "Notes", value: "Backlit, veil toss" },
    ]);
  });

  it("trims field values", () => {
    const cards = [
      makeCard({ id: "c1", position: 1000, title: "x", subjects: "  bride + groom  " }),
    ];
    const model = buildPdfModel(makeDeck(), cards, new Map());
    expect(model.cards[0].fields).toEqual([{ label: "Subjects", value: "bride + groom" }]);
  });

  it("falls back to 'Untitled card' for a blank/whitespace title", () => {
    const cards = [
      makeCard({ id: "c1", position: 1000, title: "   " }),
      makeCard({ id: "c2", position: 2000, title: "" }),
    ];
    const model = buildPdfModel(makeDeck(), cards, new Map());
    expect(model.cards[0].title).toBe(UNTITLED_CARD);
    expect(model.cards[1].title).toBe(UNTITLED_CARD);
  });

  it("derives shootDateLabel: 'Undated' for empty/unparseable, formatted otherwise", () => {
    expect(buildPdfModel(makeDeck({ shoot_date: "" }), [], new Map()).shootDateLabel).toBe(
      UNDATED_LABEL,
    );
    expect(
      buildPdfModel(makeDeck({ shoot_date: "not-a-date" }), [], new Map()).shootDateLabel,
    ).toBe(UNDATED_LABEL);
    const label = buildPdfModel(
      makeDeck({ shoot_date: "2026-06-07T00:00:00Z" }),
      [],
      new Map(),
    ).shootDateLabel;
    expect(label).not.toBe(UNDATED_LABEL);
    expect(label).toMatch(/2026/);
  });

  it("preserves image order from imagesByCard and exposes ids; empty when none", () => {
    const cards = [
      makeCard({ id: "c1", position: 1000, title: "Has images" }),
      makeCard({ id: "c2", position: 2000, title: "No images" }),
    ];
    const imagesByCard = new Map<string, CardImage[]>([
      // Already position-ordered by liveCardImages; we must PRESERVE this order.
      ["c1", [makeImage("img-a", "c1", 0), makeImage("img-b", "c1", 1)]],
    ]);
    const model = buildPdfModel(makeDeck(), cards, imagesByCard);
    expect(model.cards[0].imageIds).toEqual(["img-a", "img-b"]);
    expect(model.cards[0].images).toHaveLength(2);
    expect(model.cards[1].imageIds).toEqual([]);
    expect(model.cards[1].images).toEqual([]);
  });

  it("allModelImages flattens images across pages in display order", () => {
    const cards = [
      makeCard({ id: "c1", position: 1000, title: "a" }),
      makeCard({ id: "c2", position: 2000, title: "b" }),
    ];
    const imagesByCard = new Map<string, CardImage[]>([
      ["c1", [makeImage("i1", "c1", 0)]],
      ["c2", [makeImage("i2", "c2", 0), makeImage("i3", "c2", 1)]],
    ]);
    const model = buildPdfModel(makeDeck(), cards, imagesByCard);
    expect(allModelImages(model).map((i) => i.id)).toEqual(["i1", "i2", "i3"]);
  });
});

describe("formatShootDate", () => {
  it("returns 'Undated' for empty/whitespace/unparseable", () => {
    expect(formatShootDate("")).toBe(UNDATED_LABEL);
    expect(formatShootDate("   ")).toBe(UNDATED_LABEL);
    expect(formatShootDate("garbage")).toBe(UNDATED_LABEL);
    // @ts-expect-error guards a non-string at runtime
    expect(formatShootDate(undefined)).toBe(UNDATED_LABEL);
  });

  it("formats a valid ISO date", () => {
    expect(formatShootDate("2026-06-07T12:00:00Z")).toMatch(/2026/);
  });
});
