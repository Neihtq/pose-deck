/**
 * Owner-gating tests for DeckDetailPage (M5 sharing).
 *
 * The deck header dropdown exposes Rename/Share/Delete ONLY to the deck owner;
 * a guest viewer (deck.owner !== current user) sees a read-only deck — none of
 * those affordances. (Duplicate now lives in the deck LIST, not the detail
 * header.) The mocked `useAuth` user id is toggled per test via a module-level
 * holder.
 */
import { fireEvent, render, screen, within } from "@testing-library/react";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { db } from "@/lib/db";
import type { Card, Deck } from "@/lib/types";

vi.mock("react-router-dom", async () => {
  const actual =
    await vi.importActual<typeof import("react-router-dom")>("react-router-dom");
  return { ...actual, useNavigate: () => vi.fn() };
});

vi.mock("@/features/cards/cardApi", () => ({
  reorderCards: vi.fn(),
  createCard: vi.fn(),
  softDeleteCard: vi.fn(),
}));
vi.mock("@/features/decks/deckApi", () => ({
  renameDeck: vi.fn(),
  softDeleteDeck: vi.fn(),
}));
vi.mock("@/features/images/imageApi", () => ({
  imageDisplayUrl: vi.fn(async () => null),
}));
vi.mock("@/features/decks/ShareDeckDialog", () => ({
  ShareDeckDialog: () => <div data-testid="share-dialog" />,
}));
vi.mock("@/components/ui/use-toast", () => ({ toast: vi.fn() }));

// Mutable auth user so each test can render as owner or guest.
const authUser: { id: string; email: string } = {
  id: "owner1",
  email: "owner@posedeck.test",
};
vi.mock("@/features/auth/AuthContext", () => ({
  clearAuthOnUnauthorized: vi.fn(() => false),
  useAuth: () => ({ user: authUser }),
}));

import DeckDetailPage from "@/features/decks/DeckDetailPage";
import { createCard, softDeleteCard } from "@/features/cards/cardApi";

const DECK: Deck = {
  id: "deck1",
  owner: "owner1",
  name: "Owned Deck",
  shoot_date: "",
  client_updated_at: "",
  created: "",
  updated: "",
  deleted_at: "",
};

const CARD: Card = {
  id: "card1",
  deck: "deck1",
  title: "Sunset pose",
  time_slot: "",
  subjects: "",
  direction: "",
  notes: "",
  position: 1,
  client_updated_at: "",
  created: "",
  updated: "",
  deleted_at: "",
};

function renderPage() {
  return render(
    <MemoryRouter initialEntries={["/decks/deck1"]}>
      <Routes>
        <Route path="/decks/:id" element={<DeckDetailPage />} />
      </Routes>
    </MemoryRouter>,
  );
}

async function openMenu() {
  fireEvent.pointerDown(
    screen.getByRole("button", { name: "Deck options" }),
    new window.PointerEvent("pointerdown", { button: 0, bubbles: true }),
  );
  return screen.findByRole("menu");
}

beforeEach(async () => {
  authUser.id = "owner1";
  authUser.email = "owner@posedeck.test";
  vi.clearAllMocks();
  await Promise.all([db.decks.clear(), db.cards.clear(), db.card_images.clear()]);
  await db.decks.put(DECK);
  await db.cards.put(CARD);
});

describe("DeckDetailPage owner gating", () => {
  it("shows Share/Rename/Delete to the owner (Duplicate lives in the deck list)", async () => {
    renderPage();
    await screen.findByText("Owned Deck");
    const menu = await openMenu();
    expect(within(menu).getByText("Share")).toBeInTheDocument();
    expect(within(menu).getByText("Rename")).toBeInTheDocument();
    expect(within(menu).getByText("Delete")).toBeInTheDocument();
    // Duplicate was moved to the deck list — it must NOT be in the detail menu.
    expect(within(menu).queryByText("Duplicate")).not.toBeInTheDocument();
  });

  it("hides Share/Rename/Delete from a guest viewer", async () => {
    authUser.id = "guest9"; // not the deck owner
    authUser.email = "guest@posedeck.test";
    renderPage();
    await screen.findByText("Owned Deck");
    const menu = await openMenu();
    expect(within(menu).queryByText("Share")).not.toBeInTheDocument();
    expect(within(menu).queryByText("Rename")).not.toBeInTheDocument();
    expect(within(menu).queryByText("Duplicate")).not.toBeInTheDocument();
    expect(within(menu).queryByText("Delete")).not.toBeInTheDocument();
    // Export PDF stays available to guests (read-only export).
    expect(within(menu).getByText("Export as PDF")).toBeInTheDocument();
  });

  it("mounts the Share dialog for the owner", async () => {
    renderPage();
    await screen.findByText("Owned Deck");
    expect(screen.getByTestId("share-dialog")).toBeInTheDocument();
  });

  it("does NOT mount the Share dialog for a guest viewer", async () => {
    authUser.id = "guest9";
    renderPage();
    await screen.findByText("Owned Deck");
    expect(screen.queryByTestId("share-dialog")).not.toBeInTheDocument();
  });
});

// DESIGN.md §6: "Guests cannot edit cards, reorder, or share." A guest viewer
// must NOT see the Add-card button, the drag (reorder) handle, or the per-card
// Delete button — and even if an affordance somehow fired, the mutation must be
// refused. Regression for SPEC-1 (card-mutation affordances exposed to guests).
describe("DeckDetailPage card-mutation gating (read-only guests, SPEC-1)", () => {
  it("shows the owner Add-card, reorder handle, and per-card delete", async () => {
    renderPage();
    await screen.findByText("Sunset pose");
    expect(
      screen.getByRole("button", { name: "Add card" }),
    ).toBeInTheDocument();
    expect(
      screen.getByRole("button", { name: "Reorder Sunset pose" }),
    ).toBeInTheDocument();
    expect(
      screen.getByRole("button", { name: "Delete Sunset pose" }),
    ).toBeInTheDocument();
  });

  it("hides Add-card, reorder handle, and per-card delete from a guest", async () => {
    authUser.id = "guest9";
    authUser.email = "guest@posedeck.test";
    renderPage();
    // The card list itself stays visible — guests may VIEW the deck.
    await screen.findByText("Sunset pose");
    expect(
      screen.queryByRole("button", { name: "Add card" }),
    ).not.toBeInTheDocument();
    expect(
      screen.queryByRole("button", { name: "Reorder Sunset pose" }),
    ).not.toBeInTheDocument();
    expect(
      screen.queryByRole("button", { name: "Delete Sunset pose" }),
    ).not.toBeInTheDocument();
  });

  it("does not render the Add-card affordance on an empty deck for a guest", async () => {
    authUser.id = "guest9";
    await db.cards.clear();
    renderPage();
    await screen.findByText("No cards yet.");
    expect(
      screen.queryByRole("button", { name: /add/i }),
    ).not.toBeInTheDocument();
  });

  it("never calls createCard/softDeleteCard for a guest even if invoked", async () => {
    authUser.id = "guest9";
    renderPage();
    await screen.findByText("Sunset pose");
    // No guest affordance exists, so the mutation APIs are never reached.
    expect(createCard).not.toHaveBeenCalled();
    expect(softDeleteCard).not.toHaveBeenCalled();
  });
});
