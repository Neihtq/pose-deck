// @vitest-environment node
/**
 * Renders the PURE PdfDocument to a real PDF buffer via `@react-pdf/renderer`'s
 * `renderToBuffer`, with INJECTED fake data-URL image bytes.
 *
 * WHY the node environment (not the default jsdom suite): `renderToBuffer` is the
 * Node code path of `@react-pdf/renderer` — it pulls in fontkit + node stream
 * plumbing and produces a real PDF byte buffer. The browser path
 * (`pdf().toBlob()`) needs canvas/Blob/DOMMatrix that jsdom does not provide.
 * The `@vitest-environment node` docblock makes ONLY this file run in node,
 * inside the same `vitest run` invocation, without weakening the jsdom default
 * the rest of the suite relies on (adversarial review fix #1). Verified: no
 * `server.deps.inline` is needed under this project's vitest config.
 *
 * Image bytes are injected as fakes (a tiny valid JPEG data URL), so this test
 * exercises NO Dexie / fetch / FileReader — only the synchronous render.
 */
import { describe, expect, it } from "vitest";
import { renderToBuffer } from "@react-pdf/renderer";

import type { CardImage } from "@/lib/types";
import { PdfDocument } from "../PdfDocument";
import { type PdfDeckModel, buildPdfModel } from "../pdfModel";

// A minimal VALID 1x1 baseline JPEG. (PNG embedding is finicky in react-pdf v3's
// bundled pngjs for tiny images; JPEG embeds cleanly.)
const JPEG_DATA_URL =
  "data:image/jpeg;base64,/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////wAALCAABAAEBAREA/8QAFAABAAAAAAAAAAAAAAAAAAAAAv/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AfwD/2Q==";

function image(id: string, card: string, position: number): CardImage {
  return { id, card, position, file: `${id}.jpg`, created: "", collectionName: "card_images" };
}

function model(): PdfDeckModel {
  const cards = [
    {
      id: "c1",
      deck: "d",
      position: 1000,
      title: "First look",
      time_slot: "9:00am",
      subjects: "bride",
      direction: "",
      notes: "",
      client_updated_at: "",
      created: "",
      updated: "",
      deleted_at: "",
    },
    {
      id: "c2",
      deck: "d",
      position: 2000,
      title: "Family group",
      time_slot: "",
      subjects: "",
      direction: "",
      notes: "x".repeat(4000), // long notes — must flow, not be clipped/throw
      client_updated_at: "",
      created: "",
      updated: "",
      deleted_at: "",
    },
    {
      id: "c3",
      deck: "d",
      position: 3000,
      title: "No images",
      time_slot: "",
      subjects: "",
      direction: "",
      notes: "",
      client_updated_at: "",
      created: "",
      updated: "",
      deleted_at: "",
    },
  ];
  const imagesByCard = new Map<string, CardImage[]>([
    ["c1", [image("i1", "c1", 0), image("i2", "c1", 1)]],
    ["c2", [image("i3", "c2", 0)]],
    // c3 has no images
  ]);
  return buildPdfModel({ name: "Smith Wedding", shoot_date: "2026-06-07T00:00:00Z" }, cards, imagesByCard);
}

function pdfHead(buf: Uint8Array): string {
  return Buffer.from(buf).subarray(0, 5).toString("latin1");
}

function pageCount(buf: Uint8Array): number {
  const text = Buffer.from(buf).toString("latin1");
  // Count page objects (`/Type /Page` not followed by `s`, to skip `/Pages`).
  return (text.match(/\/Type\s*\/Page(?![s])/g) ?? []).length;
}

describe("PdfDocument (renderToBuffer, node env)", () => {
  it("renders a non-empty %PDF buffer for a multi-card deck with images", async () => {
    const sources = new Map<string, string | undefined>([
      ["i1", JPEG_DATA_URL],
      ["i2", JPEG_DATA_URL],
      ["i3", JPEG_DATA_URL],
    ]);
    const buf = await renderToBuffer(
      PdfDocument({ model: model(), imageSources: sources }),
    );
    expect(buf.length).toBeGreaterThan(1000);
    expect(pdfHead(buf)).toBe("%PDF-");
    // Cover + 3 cards == 4 pages.
    expect(pageCount(buf)).toBe(4);
  });

  it("renders without throwing when a card has NO images", async () => {
    const sources = new Map<string, string | undefined>([["i1", JPEG_DATA_URL]]);
    // Only c1's first image is provided; c2/c3 images absent → skipped.
    const buf = await renderToBuffer(
      PdfDocument({ model: model(), imageSources: sources }),
    );
    expect(pdfHead(buf)).toBe("%PDF-");
    expect(pageCount(buf)).toBe(4);
  });

  it("renders without throwing when an image source is undefined (placeholder)", async () => {
    const sources = new Map<string, string | undefined>([
      ["i1", undefined], // explicitly unresolved → placeholder, no <Image>
      ["i2", undefined],
      ["i3", undefined],
    ]);
    const buf = await renderToBuffer(
      PdfDocument({ model: model(), imageSources: sources }),
    );
    expect(pdfHead(buf)).toBe("%PDF-");
    expect(pageCount(buf)).toBe(4);
  });

  it("page count grows with the number of cards", async () => {
    const oneCard = buildPdfModel(
      { name: "Tiny", shoot_date: "" },
      [
        {
          id: "x",
          deck: "d",
          position: 1,
          title: "Only",
          time_slot: "",
          subjects: "",
          direction: "",
          notes: "",
          client_updated_at: "",
          created: "",
          updated: "",
          deleted_at: "",
        },
      ],
      new Map(),
    );
    const small = await renderToBuffer(
      PdfDocument({ model: oneCard, imageSources: new Map() }),
    );
    const big = await renderToBuffer(
      PdfDocument({ model: model(), imageSources: new Map<string, string | undefined>() }),
    );
    expect(pageCount(small)).toBe(2); // cover + 1 card
    expect(pageCount(big)).toBeGreaterThan(pageCount(small));
  });

  it("can render repeatedly without throwing", async () => {
    const sources = new Map<string, string | undefined>([["i1", JPEG_DATA_URL]]);
    for (let i = 0; i < 3; i++) {
      const buf = await renderToBuffer(
        PdfDocument({ model: model(), imageSources: sources }),
      );
      expect(pdfHead(buf)).toBe("%PDF-");
    }
  });
});
