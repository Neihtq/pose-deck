/**
 * Component tests for DeckDetailPage (route `/decks/:id`) beyond the reorder
 * behaviour covered in DeckDetailReorder.test.tsx.
 *
 * As of M3 the deck + its cards are read from Dexie via live queries. These
 * tests seed the real (fake-indexeddb) `db`; the mutation APIs are mocked and
 * mirror their effect into Dexie so the live queries propagate.
 */
import { fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { db } from "@/lib/db";
import type { Card, Deck } from "@/lib/types";

const navigate = vi.fn();
vi.mock("react-router-dom", async () => {
  const actual =
    await vi.importActual<typeof import("react-router-dom")>(
      "react-router-dom",
    );
  return { ...actual, useNavigate: () => navigate };
});

const createCard = vi.fn();
const softDeleteCard = vi.fn();
const softDeleteDeck = vi.fn();
vi.mock("@/features/cards/cardApi", () => ({
  reorderCards: vi.fn(),
  createCard: (...a: unknown[]) => createCard(...a),
  softDeleteCard: (...a: unknown[]) => softDeleteCard(...a),
}));
vi.mock("@/features/decks/deckApi", () => ({
  duplicateDeck: vi.fn(),
  renameDeck: vi.fn(),
  softDeleteDeck: (...a: unknown[]) => softDeleteDeck(...a),
}));
vi.mock("@/features/images/imageApi", () => ({
  imageDisplayUrl: vi.fn(async () => null),
}));
vi.mock("@/features/auth/AuthContext", () => ({
  clearAuthOnUnauthorized: vi.fn(() => false),
  // DECK.owner === "u1", so the default mock user is the owner.
  useAuth: () => ({ user: { id: "u1", email: "owner@posedeck.test" } }),
}));
// ShareDeckDialog pulls in guestApi → sync; stub it so the owner-gated menu
// renders without the live sync runtime.
vi.mock("@/features/decks/ShareDeckDialog", () => ({
  ShareDeckDialog: () => null,
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

beforeEach(async () => {
  navigate.mockReset();
  createCard.mockReset();
  softDeleteCard.mockReset();
  softDeleteDeck.mockReset();
  toast.mockReset();
  await Promise.all([db.decks.clear(), db.cards.clear(), db.card_images.clear()]);
});

describe("DeckDetailPage", () => {
  it("renders the deck name, card count, and the empty-cards state", async () => {
    await db.decks.put(DECK);
    renderPage();

    await screen.findByText("Smith Wedding");
    expect(screen.getByText("0 cards")).toBeInTheDocument();
    expect(screen.getByText("No cards yet.")).toBeInTheDocument();
  });

  it("renders 'Deck not found.' when the deck is absent from the local store", async () => {
    renderPage();
    await screen.findByText("Deck not found.");
  });

  it("renders cards and a singular count for one card", async () => {
    await db.decks.put(DECK);
    await db.cards.put(makeCard("c1", "First look", 1000));
    renderPage();

    await screen.findByText("First look");
    expect(screen.getByText("1 card")).toBeInTheDocument();
  });

  it("adds a card optimistically and navigates to its editor", async () => {
    await db.decks.put(DECK);
    createCard.mockImplementation(async () => {
      const card = makeCard("new1", "Untitled card", 1000);
      await db.cards.put(card);
      return card;
    });
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
    await db.decks.put(DECK);
    await db.cards.put(makeCard("c1", "First look", 1000));
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
    await db.decks.put(DECK);
    await db.cards.bulkPut([
      makeCard("c1", "First look", 1000),
      makeCard("c2", "Family group", 2000),
    ]);
    // The mock mirrors a real soft-delete so the live card query drops the row.
    softDeleteCard.mockImplementation(async (id: string) => {
      await db.cards.update(id, { deleted_at: new Date().toISOString() });
    });
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
