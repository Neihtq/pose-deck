/**
 * Pure `@react-pdf/renderer` Document for the deck PDF export (M6).
 *
 * Driven ENTIRELY by a pre-built {@link PdfDeckModel} plus a `Map` of
 * already-resolved image data URLs. There is NO async, NO Dexie, NO fetch in
 * render — every image byte is resolved up front by the orchestrator
 * (`exportDeckPdf.ts`) so this component renders synchronously and can be
 * exercised with `renderToBuffer` in Node/vitest (see PdfDocument.test.ts for
 * WHY the test runs in the node env, not jsdom).
 *
 * Layout: a cover Page (deck name, shoot-date label, "{n} cards"), then one
 * Page per card — the first image prominent, any extras smaller, then the title
 * and the omitted-when-empty field rows.
 *
 * Robustness (adversarial review):
 *  - an `undefined` image source is SKIPPED (a light placeholder box), never
 *    passed to `<Image>` — so a failed/missing image cannot throw mid-render;
 *  - `wrap` is left on (the default) and NO fixed heights are set on text, so a
 *    long `notes` field flows onto a continuation page instead of being clipped
 *    (fix #8). Images are capped by `maxHeight` (not fixed height) so they never
 *    push text off the page.
 */
import * as React from "react";
import {
  Document,
  type DocumentProps,
  Image,
  Page,
  StyleSheet,
  Text,
  View,
} from "@react-pdf/renderer";

import type { PdfCardModel, PdfDeckModel } from "./pdfModel";

/** Props for {@link PdfDocument}: the pure model + resolved image data URLs. */
export interface PdfDocumentProps {
  model: PdfDeckModel;
  /** image id → data URL (or `undefined`/absent to skip that image). */
  imageSources: Map<string, string | undefined>;
}

const styles = StyleSheet.create({
  page: {
    paddingVertical: 48,
    paddingHorizontal: 48,
    fontSize: 11,
    fontFamily: "Helvetica",
    color: "#0a0a0a",
  },
  coverPage: {
    paddingVertical: 48,
    paddingHorizontal: 48,
    justifyContent: "center",
    alignItems: "center",
    fontFamily: "Helvetica",
    color: "#0a0a0a",
  },
  coverName: {
    fontSize: 28,
    fontFamily: "Helvetica-Bold",
    textAlign: "center",
    marginBottom: 12,
  },
  coverMeta: {
    fontSize: 13,
    color: "#525252",
    textAlign: "center",
    marginBottom: 4,
  },
  cardTitle: {
    fontSize: 18,
    fontFamily: "Helvetica-Bold",
    marginBottom: 10,
  },
  heroImage: {
    width: "100%",
    maxHeight: 360,
    objectFit: "contain",
    marginBottom: 12,
  },
  extraRow: {
    flexDirection: "row",
    flexWrap: "wrap",
    gap: 8,
    marginBottom: 12,
  },
  extraImage: {
    width: 120,
    maxHeight: 120,
    objectFit: "cover",
  },
  placeholder: {
    width: "100%",
    height: 200,
    backgroundColor: "#f5f5f5",
    borderRadius: 4,
    marginBottom: 12,
    alignItems: "center",
    justifyContent: "center",
  },
  placeholderText: {
    fontSize: 10,
    color: "#a3a3a3",
  },
  fieldRow: {
    flexDirection: "row",
    marginBottom: 6,
  },
  fieldLabel: {
    width: 84,
    fontFamily: "Helvetica-Bold",
    color: "#525252",
  },
  fieldValue: {
    flex: 1,
  },
});

/** Resolve an image id to its data URL, treating absent/undefined as "skip". */
function srcFor(
  sources: Map<string, string | undefined>,
  id: string,
): string | undefined {
  return sources.get(id);
}

/** One card page: hero image (or placeholder), extra images, title, fields. */
function CardPage({
  card,
  imageSources,
}: {
  card: PdfCardModel;
  imageSources: Map<string, string | undefined>;
}): React.JSX.Element {
  const [first, ...rest] = card.imageIds;
  const firstSrc = first ? srcFor(imageSources, first) : undefined;

  return (
    <Page size="A4" style={styles.page} wrap>
      {first ? (
        firstSrc ? (
          <Image src={firstSrc} style={styles.heroImage} />
        ) : (
          <View style={styles.placeholder}>
            <Text style={styles.placeholderText}>Image unavailable</Text>
          </View>
        )
      ) : null}

      {rest.length > 0 ? (
        <View style={styles.extraRow}>
          {rest.map((id) => {
            const src = srcFor(imageSources, id);
            return src ? (
              <Image key={id} src={src} style={styles.extraImage} />
            ) : null;
          })}
        </View>
      ) : null}

      <Text style={styles.cardTitle}>{card.title}</Text>

      {card.fields.map((field) => (
        <View key={field.label} style={styles.fieldRow} wrap={false}>
          <Text style={styles.fieldLabel}>{field.label}</Text>
          <Text style={styles.fieldValue}>{field.value}</Text>
        </View>
      ))}
    </Page>
  );
}

/**
 * The full export Document: a cover page + one page per card.
 *
 * Returns a `ReactElement<DocumentProps>` (a `<Document>` element) — the exact
 * type `@react-pdf/renderer`'s `pdf()` / `renderToBuffer` require — so callers
 * invoke it as a plain function (`PdfDocument({ model, imageSources })`) to get a
 * Document element, rather than `React.createElement(PdfDocument, …)` which would
 * produce a wrapper-component element the renderer's types reject.
 */
export function PdfDocument({
  model,
  imageSources,
}: PdfDocumentProps): React.ReactElement<DocumentProps> {
  return (
    <Document title={model.name}>
      <Page size="A4" style={styles.coverPage}>
        <Text style={styles.coverName}>{model.name}</Text>
        <Text style={styles.coverMeta}>{model.shootDateLabel}</Text>
        <Text style={styles.coverMeta}>
          {model.cardCount} {model.cardCount === 1 ? "card" : "cards"}
        </Text>
      </Page>

      {model.cards.map((card) => (
        <CardPage key={card.id} card={card} imageSources={imageSources} />
      ))}
    </Document>
  );
}
