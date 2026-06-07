/**
 * M8 accessibility regression tests for DeckDetailPage.
 *
 * These lock in the accessible names + roles added in the M8 a11y pass so they
 * don't silently regress:
 *  - the icon-only "Deck options" menu trigger has an accessible name;
 *  - each card's drag handle is named by its card and points at the keyboard
 *    instructions (the keyboard alternative to pointer drag);
 *  - the keyboard reorder instructions element exists and is referenced;
 *  - each card's icon-only delete button is named by its card.
 */
import { render, screen, within } from "@testing-library/react";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { db } from "@/lib/db";
import type { Card, Deck } from "@/lib/types";

vi.mock("react-router-dom", async () => {
  const actual =
    await vi.importActual<typeof import("react-router-dom")>(
      "react-router-dom",
    );
  return { ...actual, useNavigate: () => vi.fn() };
});

vi.mock("@/features/cards/cardApi", () => ({
  reorderCards: vi.fn(),
  createCard: vi.fn(),
  softDeleteCard: vi.fn(),
}));
vi.mock("@/features/decks/deckApi", () => ({
  duplicateDeck: vi.fn(),
  renameDeck: vi.fn(),
  softDeleteDeck: vi.fn(),
}));
vi.mock("@/features/images/imageApi", () => ({
  imageDisplayUrl: vi.fn(async () => null),
}));
vi.mock("@/features/auth/AuthContext", () => ({
  clearAuthOnUnauthorized: vi.fn(() => false),
  useAuth: () => ({ user: { id: "u1", email: "owner@posedeck.test" } }),
}));
vi.mock("@/features/decks/ShareDeckDialog", () => ({
  ShareDeckDialog: () => null,
}));
vi.mock("@/components/ui/use-toast", () => ({ toast: vi.fn() }));

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
  await Promise.all([
    db.decks.clear(),
    db.cards.clear(),
    db.card_images.clear(),
  ]);
});

describe("DeckDetailPage a11y", () => {
  it("gives the icon-only deck options trigger an accessible name", async () => {
    await db.decks.put(DECK);
    renderPage();
    await screen.findByText("Smith Wedding");
    expect(
      screen.getByRole("button", { name: "Deck options" }),
    ).toBeInTheDocument();
  });

  it("names each card's drag handle and delete button by its card", async () => {
    await db.decks.put(DECK);
    await db.cards.put(makeCard("c1", "First look", 1000));
    await db.cards.put(makeCard("c2", "", 2000)); // untitled
    renderPage();
    await screen.findByText("First look");

    // Drag handles are named per card (the untitled card falls back to a label).
    expect(
      screen.getByRole("button", { name: "Reorder First look" }),
    ).toBeInTheDocument();
    expect(
      screen.getByRole("button", { name: "Reorder Untitled card" }),
    ).toBeInTheDocument();

    // Delete buttons are named per card too.
    expect(
      screen.getByRole("button", { name: "Delete First look" }),
    ).toBeInTheDocument();
    expect(
      screen.getByRole("button", { name: "Delete Untitled card" }),
    ).toBeInTheDocument();
  });

  it("exposes the drag handle as keyboard-operable with dnd-kit's instructions", async () => {
    await db.decks.put(DECK);
    await db.cards.put(makeCard("c1", "First look", 1000));
    renderPage();
    await screen.findByText("First look");

    const handle = screen.getByRole("button", { name: "Reorder First look" });
    // dnd-kit's KeyboardSensor wires the handle: it carries the sortable role
    // description and points at dnd-kit's built-in screen-reader instructions
    // (the keyboard alternative to the pointer drag).
    expect(handle).toHaveAttribute("aria-roledescription", "sortable");
    const describedById = handle.getAttribute("aria-describedby");
    expect(describedById).toBeTruthy();
    const instructions = document.getElementById(describedById as string);
    expect(instructions).not.toBeNull();
    expect(instructions?.textContent).toMatch(/space bar|arrow keys/i);
  });

  it("keeps the open-card control reachable with the card title as its name", async () => {
    await db.decks.put(DECK);
    await db.cards.put(makeCard("c1", "First look", 1000));
    renderPage();
    const row = (await screen.findByText("First look")).closest("li");
    expect(row).not.toBeNull();
    // The open control (button wrapping the title) is keyboard-focusable.
    const openButton = within(row as HTMLElement).getByText("First look");
    expect(openButton.closest("button")).not.toBeNull();
  });
});
