/**
 * Component tests for DeckDetailPage (route `/decks/:id`) beyond the reorder
 * race covered in DeckDetailReorder.test.tsx.
 *
 * Covers: load error rendering, the empty-cards state, "Add card" (optimistic
 * append + navigate to the new card editor), and delete (soft-delete → navigate
 * home + toast). The deck/card/image APIs and the auth 401-handler are mocked,
 * so no PocketBase SDK or network is involved.
 */
import { fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { beforeEach, describe, expect, it, vi } from "vitest";

import type { Card, Deck } from "@/lib/types";

const navigate = vi.fn();
vi.mock("react-router-dom", async () => {
  const actual =
    await vi.importActual<typeof import("react-router-dom")>(
      "react-router-dom",
    );
  return { ...actual, useNavigate: () => navigate };
});

const getDeck = vi.fn();
const listCards = vi.fn();
const createCard = vi.fn();
const softDeleteCard = vi.fn();
const softDeleteDeck = vi.fn();
vi.mock("@/features/cards/cardApi", () => ({
  listCards: (...a: unknown[]) => listCards(...a),
  reorderCards: vi.fn(),
  createCard: (...a: unknown[]) => createCard(...a),
  softDeleteCard: (...a: unknown[]) => softDeleteCard(...a),
}));
vi.mock("@/features/decks/deckApi", () => ({
  getDeck: (...a: unknown[]) => getDeck(...a),
  duplicateDeck: vi.fn(),
  renameDeck: vi.fn(),
  softDeleteDeck: (...a: unknown[]) => softDeleteDeck(...a),
}));
vi.mock("@/features/images/imageApi", () => ({
  imageDisplayUrl: vi.fn(async () => null),
  listCardImages: vi.fn(async () => []),
}));
vi.mock("@/features/auth/AuthContext", () => ({
  clearAuthOnUnauthorized: vi.fn(() => false),
}));
const toast = vi.fn();
vi.mock("@/components/ui/use-toast", () => ({
  toast: (...a: unknown[]) => toast(...a),
}));

import DeckDetailPage from "@/features/decks/DeckDetailPage";

const DECK: Deck = {
  id: "deck1",
  owner: "u1",
  name: "Smith Wedding",
  shoot_date: "",
  client_updated_at: "",
  created: "",
  updated: "",
  deleted_at: "",
};

function makeCard(id: string, title: string, position: number): Card {
  return {
    id,
    deck: "deck1",
    position,
    title,
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

function renderPage() {
  return render(
    <MemoryRouter initialEntries={["/decks/deck1"]}>
      <Routes>
        <Route path="/decks/:id" element={<DeckDetailPage />} />
      </Routes>
    </MemoryRouter>,
  );
}

beforeEach(() => {
  navigate.mockReset();
  getDeck.mockReset();
  listCards.mockReset();
  createCard.mockReset();
  softDeleteCard.mockReset();
  softDeleteDeck.mockReset();
  toast.mockReset();
});

describe("DeckDetailPage", () => {
  it("renders the deck name, card count, and the empty-cards state", async () => {
    getDeck.mockResolvedValue(DECK);
    listCards.mockResolvedValue([]);
    renderPage();

    await screen.findByText("Smith Wedding");
    expect(screen.getByText("0 cards")).toBeInTheDocument();
    expect(screen.getByText("No cards yet.")).toBeInTheDocument();
  });

  it("renders a load error when the deck cannot be loaded", async () => {
    getDeck.mockRejectedValue(new Error("not found"));
    listCards.mockResolvedValue([]);
    renderPage();
    await screen.findByText("Couldn't load this deck.");
  });

  it("renders cards and a singular count for one card", async () => {
    getDeck.mockResolvedValue(DECK);
    listCards.mockResolvedValue([makeCard("c1", "First look", 1000)]);
    renderPage();

    await screen.findByText("First look");
    expect(screen.getByText("1 card")).toBeInTheDocument();
  });

  it("adds a card optimistically and navigates to its editor", async () => {
    getDeck.mockResolvedValue(DECK);
    listCards.mockResolvedValue([]);
    createCard.mockResolvedValue(makeCard("new1", "Untitled card", 1000));
    renderPage();
    await screen.findByText("Smith Wedding");

    fireEvent.click(
      screen.getByRole("button", { name: "Add your first card" }),
    );

    await waitFor(() =>
      expect(createCard).toHaveBeenCalledWith(
        "deck1",
        expect.objectContaining({ title: "Untitled card" }),
      ),
    );
    await waitFor(() =>
      expect(navigate).toHaveBeenCalledWith("/decks/deck1/cards/new1"),
    );
  });

  it("deletes the deck and navigates home with a toast", async () => {
    getDeck.mockResolvedValue(DECK);
    listCards.mockResolvedValue([makeCard("c1", "First look", 1000)]);
    softDeleteDeck.mockResolvedValue(undefined);
    renderPage();
    await screen.findByText("First look");

    // Open the deck options menu and choose Delete.
    fireEvent.pointerDown(
      screen.getByRole("button", { name: "Deck options" }),
      new window.PointerEvent("pointerdown", { button: 0, bubbles: true }),
    );
    const menu = await screen.findByRole("menu");
    fireEvent.click(within(menu).getByText("Delete"));

    const confirm = await screen.findByRole("alertdialog");
    fireEvent.click(within(confirm).getByRole("button", { name: "Delete" }));

    await waitFor(() => expect(softDeleteDeck).toHaveBeenCalledWith("deck1"));
    await waitFor(() => expect(navigate).toHaveBeenCalledWith("/"));
    expect(toast).toHaveBeenCalledWith(
      expect.objectContaining({ title: "Deck moved to trash" }),
    );
  });

  it("deletes a card inline from the list (confirm) without opening it", async () => {
    getDeck.mockResolvedValue(DECK);
    listCards.mockResolvedValue([
      makeCard("c1", "First look", 1000),
      makeCard("c2", "Family group", 2000),
    ]);
    softDeleteCard.mockResolvedValue(undefined);
    renderPage();
    await screen.findByText("First look");

    // Click the row's delete button (no navigation into the card).
    fireEvent.click(
      screen.getByRole("button", { name: /Delete First look/i }),
    );

    // Confirm in the alert dialog.
    const confirm = await screen.findByRole("alertdialog");
    fireEvent.click(within(confirm).getByRole("button", { name: "Delete" }));

    await waitFor(() => expect(softDeleteCard).toHaveBeenCalledWith("c1"));
    // Row is removed from the list; we never navigated to the card editor.
    await waitFor(() =>
      expect(screen.queryByText("First look")).not.toBeInTheDocument(),
    );
    expect(screen.getByText("Family group")).toBeInTheDocument();
    expect(navigate).not.toHaveBeenCalledWith("/decks/deck1/cards/c1");
    expect(toast).toHaveBeenCalledWith(
      expect.objectContaining({ title: "Card deleted" }),
    );
  });
});
