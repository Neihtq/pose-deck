/**
 * Regression test for SPEC-1: deck-list tiles must render the deck
 * auto-thumbnail — the first image of the first (lowest-position) card
 * (DESIGN.md §3.3 "Auto-thumbnail (derived): First image of first card").
 *
 * As of M3 the join is local-first: `DeckListPage` reads cards/images from
 * Dexie (`liveCards` → `liveCardImages`) and resolves the display URL via
 * `imageDisplayUrl`. These tests seed the real (fake-indexeddb) `db` and assert
 * the resolved URL reaches an `<img>` tag, and that a deck with no image falls
 * back to a placeholder.
 */
import { render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { db } from "@/lib/db";
import type { Card, CardImage, Deck } from "@/lib/types";

const imageDisplayUrl = vi.fn();

vi.mock("@/features/decks/deckApi", () => ({
  createDeck: vi.fn(),
  duplicateDeck: vi.fn(),
  renameDeck: vi.fn(),
  softDeleteDeck: vi.fn(),
}));

vi.mock("@/features/images/imageApi", () => ({
  imageDisplayUrl: (...args: unknown[]) => imageDisplayUrl(...args),
}));

vi.mock("@/features/auth/AuthContext", () => ({
  clearAuthOnUnauthorized: vi.fn(() => false),
}));

vi.mock("@/components/ui/use-toast", () => ({
  toast: vi.fn(),
}));

import DeckListPage from "@/features/decks/DeckListPage";
import { ThemeProvider } from "@/components/theme/ThemeProvider";

function makeDeck(id: string, name: string): Deck {
  return {
    id,
    owner: "u1",
    name,
    shoot_date: "",
    client_updated_at: "",
    created: "",
    updated: "",
    deleted_at: "",
  };
}

function makeCard(id: string, deck: string, position: number): Card {
  return {
    id,
    deck,
    position,
    title: id,
    time_slot: "",
    subjects: "",
    direction: "",
    notes: "",
    client_updated_at: "",
    created: "",
    updated: "",
    deleted_at: "",
  };
}

function makeImage(id: string, card: string, position: number): CardImage {
  return { id, card, position, file: `${id}.jpg`, created: "" };
}

function renderPage() {
  return render(
    <ThemeProvider>
      <MemoryRouter>
        <DeckListPage />
      </MemoryRouter>
    </ThemeProvider>,
  );
}

beforeEach(async () => {
  imageDisplayUrl.mockReset();
  await Promise.all([db.decks.clear(), db.cards.clear(), db.card_images.clear()]);
});

describe("deck-list auto-thumbnail (DESIGN.md §3.3)", () => {
  it("renders the first image of the first card as the deck tile thumbnail", async () => {
    await db.decks.put(makeDeck("d1", "Smith Wedding"));
    // Two cards out of order; the lowest-position card (c-first) is the deck's
    // first card, and its lowest-position image is the auto-thumbnail.
    await db.cards.bulkPut([
      makeCard("c-first", "d1", 1000),
      makeCard("c-second", "d1", 2000),
    ]);
    await db.card_images.bulkPut([
      makeImage("img-a", "c-first", 1000),
      makeImage("img-b", "c-first", 2000),
    ]);
    imageDisplayUrl.mockResolvedValue("https://cdn.test/thumb-a.jpg");

    const { container } = renderPage();

    await screen.findByText("Smith Wedding");

    const img = await waitFor(() => {
      const found = container.querySelector("img");
      expect(found).not.toBeNull();
      return found as HTMLImageElement;
    });
    expect(img.getAttribute("src")).toBe("https://cdn.test/thumb-a.jpg");

    // Resolved the thumbnail from the FIRST card's first image (img-a).
    expect(imageDisplayUrl).toHaveBeenCalledWith(
      expect.objectContaining({ id: "img-a" }),
      expect.anything(),
    );
  });

  it("falls back to a placeholder when the deck has no card image", async () => {
    await db.decks.put(makeDeck("d2", "Empty Deck"));
    imageDisplayUrl.mockResolvedValue("should-not-be-used");

    const { container } = renderPage();

    await screen.findByText("Empty Deck");

    await screen.findByText("No image");
    expect(container.querySelector("img")).toBeNull();
    expect(imageDisplayUrl).not.toHaveBeenCalled();
  });
});
