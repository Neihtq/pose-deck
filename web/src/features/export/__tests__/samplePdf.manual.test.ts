// @vitest-environment node
/**
 * END-TO-END sample: render the REAL PdfDocument (via the real buildPdfModel)
 * for a 2-card fake deck + fake JPEG bytes and write it to /tmp so a human can
 * open it. Proves the model→document→buffer path produces a valid PDF on disk.
 *
 * Not part of the behavioural suite's assertions beyond a smoke check; it exists
 * to generate the artifact the M6 verify step requires. Run via:
 *   npx vitest run src/features/export/__tests__/samplePdf.manual.test.ts
 */
import { writeFileSync, statSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { renderToBuffer } from "@react-pdf/renderer";

import type { Card, CardImage } from "@/lib/types";
import { PdfDocument } from "../PdfDocument";
import { buildPdfModel } from "../pdfModel";

const JPEG_DATA_URL =
  "data:image/jpeg;base64,/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////wAALCAABAAEBAREA/8QAFAABAAAAAAAAAAAAAAAAAAAAAv/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AfwD/2Q==";

function card(over: Partial<Card> & { id: string; position: number }): Card {
  return {
    deck: "d",
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
function image(id: string, c: string, p: number): CardImage {
  return { id, card: c, position: p, file: `${id}.jpg`, created: "", collectionName: "card_images" };
}

describe("sample PDF artifact", () => {
  it("writes a >1KB %PDF to /tmp/posedeck-sample.pdf", async () => {
    const cards = [
      card({ id: "c1", position: 1000, title: "First look", time_slot: "9:00am", subjects: "bride + groom", notes: "Backlit by the window." }),
      card({ id: "c2", position: 2000, title: "Family group", direction: "Stagger heights" }),
    ];
    const imagesByCard = new Map<string, CardImage[]>([
      ["c1", [image("i1", "c1", 0), image("i2", "c1", 1)]],
      ["c2", [image("i3", "c2", 0)]],
    ]);
    const model = buildPdfModel({ name: "Smith Wedding", shoot_date: "2026-06-07T00:00:00Z" }, cards, imagesByCard);
    const sources = new Map<string, string | undefined>([
      ["i1", JPEG_DATA_URL],
      ["i2", JPEG_DATA_URL],
      ["i3", JPEG_DATA_URL],
    ]);

    const buf = await renderToBuffer(PdfDocument({ model, imageSources: sources }));
    const path = "/tmp/posedeck-sample.pdf";
    writeFileSync(path, buf);

    const size = statSync(path).size;
    const text = Buffer.from(buf).toString("latin1");
    const pages = (text.match(/\/Type\s*\/Page(?![s])/g) ?? []).length;
    // eslint-disable-next-line no-console
    console.log(`SAMPLE_PDF path=${path} size=${size} pages=${pages}`);

    expect(size).toBeGreaterThan(1024);
    expect(Buffer.from(buf).subarray(0, 5).toString("latin1")).toBe("%PDF-");
    expect(pages).toBe(3); // cover + 2 cards
  });
});
