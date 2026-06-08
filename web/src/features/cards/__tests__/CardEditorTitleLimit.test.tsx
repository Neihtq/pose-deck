/**
 * Regression test for the card editor's title length cap.
 *
 * The *product* spec (DESIGN.md §3.1) governs UI field limits and specifies
 * `Title — ≤60 chars`. The DB field (ARCHITECTURE.md §3.3 / PocketBase
 * `cards.title` max 200) is just headroom, not the product constraint — titles
 * are short shot labels. So the editor caps titles at 60: a 60-char title is
 * accepted, a 61-char title is rejected.
 *
 * (History: the M1 gauntlet briefly raised this to 200 by treating the data
 * model as authoritative for a product field; reverted — DESIGN.md wins for UI
 * field constraints.)
 */
import { act, fireEvent, render, screen } from "@testing-library/react";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { db } from "@/lib/db";
import type { Deck } from "@/lib/types";

// --- Mock data-access + side-effect modules -------------------------------
const createCard = vi.fn();
const updateCard = vi.fn();
const softDeleteCard = vi.fn();

vi.mock("@/features/cards/cardApi", () => ({
  createCard: (...args: unknown[]) => createCard(...args),
  updateCard: (...args: unknown[]) => updateCard(...args),
  softDeleteCard: (...args: unknown[]) => softDeleteCard(...args),
}));

vi.mock("@/features/images/imageApi", () => ({
  MAX_IMAGES_PER_CARD: 5,
  deleteCardImage: vi.fn(),
  imageDisplayUrl: vi.fn(async () => null),
  listCardImages: vi.fn(async () => []),
}));

vi.mock("@/features/images/useImageUpload", () => ({
  useImageUpload: () => ({
    upload: vi.fn(),
    pasteHandler: vi.fn(),
    uploading: false,
    error: null,
  }),
}));

vi.mock("@/lib/pocketbase", () => ({
  collections: {
    cards: () => ({ getFirstListItem: vi.fn() }),
  },
}));

vi.mock("@/components/ui/use-toast", () => ({
  toast: vi.fn(),
}));

vi.mock("@/features/auth/AuthContext", () => ({
  clearAuthOnUnauthorized: vi.fn(() => false),
  // The editor is owner-only; render as the deck owner so the form mounts.
  useAuth: () => ({ user: { id: "owner1", email: "owner@posedeck.test" } }),
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

function renderCreatePage() {
  return render(
    <MemoryRouter initialEntries={["/decks/deck1/cards/new"]}>
      <Routes>
        <Route path="/decks/:deckId/cards/new" element={<CardEditor />} />
        <Route
          path="/decks/:deckId/cards/:cardId"
          element={<CardEditor />}
        />
      </Routes>
    </MemoryRouter>,
  );
}

async function titleInput(): Promise<HTMLInputElement> {
  // The owner-gated editor mounts only after the deck live query resolves.
  return (await screen.findByLabelText(/Title/i)) as HTMLInputElement;
}

function saveButton(): HTMLButtonElement {
  return screen.getByRole("button", { name: /Create card/i }) as HTMLButtonElement;
}

beforeEach(async () => {
  createCard.mockReset();
  createCard.mockResolvedValue({ id: "card1" });
  updateCard.mockReset();
  softDeleteCard.mockReset();
  // Owner-gated editor: seed the deck (owned by the test user) so the form
  // mounts in create mode.
  await db.decks.clear();
  await db.decks.put(DECK);
});

describe("CardEditor title length cap (DESIGN.md §3.1 ≤60)", () => {
  it("accepts a 60-char title (the product maximum)", async () => {
    renderCreatePage();

    const maxTitle = "a".repeat(60);
    fireEvent.change(await titleInput(), { target: { value: maxTitle } });

    // No "too long" error at exactly 60 chars.
    expect(
      screen.queryByText(/characters or fewer/i),
    ).not.toBeInTheDocument();

    // Save must be enabled and persist the full title.
    const button = saveButton();
    expect(button).not.toBeDisabled();

    await act(async () => {
      fireEvent.click(button);
    });

    expect(createCard).toHaveBeenCalledTimes(1);
    expect(createCard.mock.calls[0][1].title).toBe(maxTitle);
  });

  it("rejects a 61-char title (exceeds the ≤60 product cap)", async () => {
    renderCreatePage();

    fireEvent.change(await titleInput(), { target: { value: "a".repeat(61) } });

    expect(screen.getByText(/characters or fewer/i)).toBeInTheDocument();
    expect(saveButton()).toBeDisabled();
  });

  it("shows the 60-char counter denominator", async () => {
    renderCreatePage();
    await titleInput();
    expect(screen.getByText("0/60")).toBeInTheDocument();
  });
});
