/**
 * Owner-gating regression test for CardEditor (SPEC-2).
 *
 * DESIGN.md §6 ("Guests cannot edit cards, reorder, or share") and §9 (the web
 * app is the owner's prep/edit surface) require the card editor to be
 * owner-only. The routes `/decks/:deckId/cards/new` and
 * `/decks/:deckId/cards/:cardId` previously rendered <CardEditor/> behind only
 * <RequireAuth> (authentication, NOT ownership), so a guest who reached a
 * card-editor URL got a fully editable form: title fields, Save, Delete, and
 * image upload. Shared decks sync down into a guest's deck list, so this URL is
 * genuinely reachable.
 *
 * The fix resolves the deck from Dexie and, when the current user is not the
 * deck owner, redirects back to the (read-only) deck instead of rendering the
 * form. These tests assert:
 *   - the OWNER still gets the editable form (no regression), and
 *   - a GUEST is redirected to /decks/:deckId and never sees the editor.
 *
 * Before the fix the guest case renders the editable form, so the guest test
 * fails (the redirect sentinel never appears and the Title input is present).
 */
import { render, screen } from "@testing-library/react";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { db } from "@/lib/db";
import type { Card, Deck } from "@/lib/types";

vi.mock("@/features/cards/cardApi", () => ({
  createCard: vi.fn(),
  updateCard: vi.fn(),
  softDeleteCard: vi.fn(),
}));
vi.mock("@/features/images/imageApi", () => ({
  MAX_IMAGES_PER_CARD: 5,
  deleteCardImage: vi.fn(),
  imageDisplayUrl: vi.fn(async () => null),
}));
vi.mock("@/features/images/useImageUpload", () => ({
  useImageUpload: () => ({
    upload: vi.fn(),
    pasteHandler: vi.fn(),
    uploading: false,
    error: null,
  }),
}));
vi.mock("@/components/ui/use-toast", () => ({ toast: vi.fn() }));

// Mutable auth user so each test renders as the owner or as a guest.
const authUser: { id: string; email: string } = {
  id: "owner1",
  email: "owner@posedeck.test",
};
vi.mock("@/features/auth/AuthContext", () => ({
  clearAuthOnUnauthorized: vi.fn(() => false),
  useAuth: () => ({ user: authUser }),
}));

import CardEditor from "@/features/cards/CardEditor";

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
  title: "First look",
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

/** Render the editor at a card URL, with a sentinel route at the deck page. */
function renderEditor(path: string) {
  return render(
    <MemoryRouter initialEntries={[path]}>
      <Routes>
        <Route
          path="/decks/:id"
          element={<div data-testid="deck-page">deck page</div>}
        />
        <Route
          path="/decks/:deckId/cards/new"
          element={<CardEditor />}
        />
        <Route
          path="/decks/:deckId/cards/:cardId"
          element={<CardEditor />}
        />
      </Routes>
    </MemoryRouter>,
  );
}

beforeEach(async () => {
  authUser.id = "owner1";
  authUser.email = "owner@posedeck.test";
  vi.clearAllMocks();
  await Promise.all([
    db.decks.clear(),
    db.cards.clear(),
    db.card_images.clear(),
  ]);
  await db.decks.put(DECK);
  await db.cards.put(CARD);
});

describe("CardEditor owner gating (SPEC-2)", () => {
  it("renders the editable form for the deck owner (edit mode)", async () => {
    renderEditor("/decks/deck1/cards/card1");
    // The owner sees the editable Title field — no redirect.
    expect(await screen.findByLabelText(/Title/i)).toBeInTheDocument();
    expect(screen.queryByTestId("deck-page")).not.toBeInTheDocument();
  });

  it("renders the editable form for the owner (create mode)", async () => {
    renderEditor("/decks/deck1/cards/new");
    expect(await screen.findByLabelText(/Title/i)).toBeInTheDocument();
    expect(screen.queryByTestId("deck-page")).not.toBeInTheDocument();
  });

  it("redirects a guest away from the editor (edit mode) — no editable form", async () => {
    authUser.id = "guest9";
    authUser.email = "guest@posedeck.test";
    renderEditor("/decks/deck1/cards/card1");
    // Guest lands on the read-only deck page, NOT the editor.
    expect(await screen.findByTestId("deck-page")).toBeInTheDocument();
    expect(screen.queryByLabelText(/Title/i)).not.toBeInTheDocument();
    expect(
      screen.queryByRole("button", { name: /^Save$/i }),
    ).not.toBeInTheDocument();
    expect(
      screen.queryByRole("button", { name: /Delete/i }),
    ).not.toBeInTheDocument();
  });

  it("redirects a guest away from the editor (create mode)", async () => {
    authUser.id = "guest9";
    authUser.email = "guest@posedeck.test";
    renderEditor("/decks/deck1/cards/new");
    expect(await screen.findByTestId("deck-page")).toBeInTheDocument();
    expect(screen.queryByLabelText(/Title/i)).not.toBeInTheDocument();
  });
});
