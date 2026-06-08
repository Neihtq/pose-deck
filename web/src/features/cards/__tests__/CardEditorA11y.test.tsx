/**
 * M8 accessibility regression tests for CardEditor.
 *
 * In the editor a card image IS content (reference photos), so it must carry a
 * meaningful `alt`, and its icon-only remove button must be named by the image
 * it removes. The hidden file <input> must also have an accessible name.
 */
import { act, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { db } from "@/lib/db";
import type { Card, CardImage, Deck } from "@/lib/types";

vi.mock("@/features/cards/cardApi", () => ({
  createCard: vi.fn(),
  updateCard: vi.fn(),
  softDeleteCard: vi.fn(),
}));
vi.mock("@/features/images/imageApi", () => ({
  MAX_IMAGES_PER_CARD: 5,
  deleteCardImage: vi.fn(),
  imageDisplayUrl: vi.fn(async () => "/api/files/card_images/img1/photo.jpg"),
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

const CARD: Card = {
  id: "card1",
  deck: "deck1",
  position: 1000,
  title: "First look",
  time_slot: "",
  subjects: "",
  direction: "",
  notes: "",
  client_updated_at: "",
  created: "",
  updated: "",
  deleted_at: "",
};

const IMAGE: CardImage = {
  id: "img1",
  card: "card1",
  file: "photo.jpg",
  position: 0,
} as CardImage;

function renderEditPage() {
  return render(
    <MemoryRouter initialEntries={["/decks/deck1/cards/card1"]}>
      <Routes>
        <Route path="/decks/:deckId/cards/:cardId" element={<CardEditor />} />
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
  await db.decks.put(DECK);
  await db.cards.put(CARD);
  await db.card_images.put(IMAGE);
});

describe("CardEditor a11y", () => {
  it("gives the card image a meaningful alt naming the card", async () => {
    await act(async () => {
      renderEditPage();
    });
    const img = await screen.findByAltText("Image 1 of First look");
    expect(img.tagName).toBe("IMG");
  });

  it("names the remove-image button by the image it removes", async () => {
    await act(async () => {
      renderEditPage();
    });
    await waitFor(() =>
      expect(
        screen.getByRole("button", { name: "Remove Image 1 of First look" }),
      ).toBeInTheDocument(),
    );
  });

  it("labels the title field and the hidden file input", async () => {
    await act(async () => {
      renderEditPage();
    });
    // The required title field is labelled.
    await waitFor(() =>
      expect(screen.getByLabelText(/Title/)).toBeInTheDocument(),
    );
    // The file input (visually hidden, triggered by "Add image") has a name.
    expect(
      screen.getByLabelText("Add images to this card"),
    ).toBeInTheDocument();
  });
});
