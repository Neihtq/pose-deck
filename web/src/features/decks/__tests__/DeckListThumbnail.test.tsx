/**
 * Regression test for SPEC-1: deck-list tiles must render the deck
 * auto-thumbnail — the first image of the first (lowest-position) card
 * (DESIGN.md §3.3 "Auto-thumbnail (derived): First image of first card").
 *
 * Before the fix `DeckCard` rendered only the name + shoot date and
 * `DeckListPage` never joined cards/images, so no thumbnail (and no
 * placeholder) ever appeared. These tests assert the full join
 * (listCards → listCardImages → imageDisplayUrl) reaches an `<img>` tag, and
 * that decks without an image fall back to a placeholder.
 */
import { render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { beforeEach, describe, expect, it, vi } from "vitest";

import type { Card, CardImage, Deck } from "@/lib/types";

// --- Mock the data-access + auth modules -----------------------------------
const listDecks = vi.fn();
const listCards = vi.fn();
const listCardImages = vi.fn();
const imageDisplayUrl = vi.fn();

vi.mock("@/features/decks/deckApi", () => ({
  listDecks: (...args: unknown[]) => listDecks(...args),
  createDeck: vi.fn(),
  duplicateDeck: vi.fn(),
  renameDeck: vi.fn(),
  softDeleteDeck: vi.fn(),
}));

vi.mock("@/features/cards/cardApi", () => ({
  listCards: (...args: unknown[]) => listCards(...args),
}));

vi.mock("@/features/images/imageApi", () => ({
  listCardImages: (...args: unknown[]) => listCardImages(...args),
  imageDisplayUrl: (...args: unknown[]) => imageDisplayUrl(...args),
}));

vi.mock("@/features/auth/AuthContext", () => ({
  clearAuthOnUnauthorized: vi.fn(() => false),
}));

vi.mock("@/components/ui/use-toast", () => ({
  toast: vi.fn(),
}));

import DeckListPage from "@/features/decks/DeckListPage";

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
    <MemoryRouter>
      <DeckListPage />
    </MemoryRouter>,
  );
}

beforeEach(() => {
  listDecks.mockReset();
  listCards.mockReset();
  listCardImages.mockReset();
  imageDisplayUrl.mockReset();
});

describe("deck-list auto-thumbnail (DESIGN.md §3.3)", () => {
  it("renders the first image of the first card as the deck tile thumbnail", async () => {
    listDecks.mockResolvedValue([makeDeck("d1", "Smith Wedding")]);
    // Two cards out of order; the lowest-position card (c-first) is the deck's
    // first card, and its lowest-position image is the auto-thumbnail.
    listCards.mockResolvedValue([
      makeCard("c-first", "d1", 1000),
      makeCard("c-second", "d1", 2000),
    ]);
    listCardImages.mockImplementation(async (cardId: string) =>
      cardId === "c-first"
        ? [makeImage("img-a", "c-first", 1000), makeImage("img-b", "c-first", 2000)]
        : [],
    );
    imageDisplayUrl.mockResolvedValue("https://cdn.test/thumb-a.jpg");

    const { container } = renderPage();

    await screen.findByText("Smith Wedding");

    const img = await waitFor(() => {
      const found = container.querySelector("img");
      expect(found).not.toBeNull();
      return found as HTMLImageElement;
    });
    expect(img.getAttribute("src")).toBe("https://cdn.test/thumb-a.jpg");

    // Resolved the thumbnail from the FIRST card's first image, not the second.
    expect(listCardImages).toHaveBeenCalledWith("c-first");
    expect(listCardImages).not.toHaveBeenCalledWith("c-second");
  });

  it("falls back to a placeholder when the deck has no card image", async () => {
    listDecks.mockResolvedValue([makeDeck("d2", "Empty Deck")]);
    listCards.mockResolvedValue([]);
    listCardImages.mockResolvedValue([]);
    imageDisplayUrl.mockResolvedValue("should-not-be-used");

    const { container } = renderPage();

    await screen.findByText("Empty Deck");

    await screen.findByText("No image");
    expect(container.querySelector("img")).toBeNull();
    expect(imageDisplayUrl).not.toHaveBeenCalled();
  });
});
