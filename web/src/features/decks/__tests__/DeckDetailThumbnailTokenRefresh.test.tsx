/**
 * Regression test for finding react-2: deck-detail card thumbnails embed a
 * short-lived `?token=` (FILE_TOKEN_TTL_MS ≈ 90s in pocketbase.ts) minted once
 * by the load effect (deps `[id]`). On a long-lived deck-detail view the token
 * expires, so any browser re-fetch of an already-rendered thumbnail (lazy
 * reveal, cache eviction, reconnect) requests `/api/files/...?token=<expired>`
 * and PocketBase rejects it — the thumbnail breaks and is never recovered.
 *
 * The fix adds an `onError` handler on each thumbnail <img> that re-mints the
 * display URL (fresh token) for the failing card's first image, mirroring
 * CardEditor's handleImageError (react-1). This test renders the deck detail
 * page with one card that has an image, fires the <img> `error` event
 * (simulating an expired-token 4xx), and asserts the URL is re-resolved and the
 * `src` updated to the new-token URL.
 *
 * Before the fix the <img> had no onError handler, so imageDisplayUrl was
 * called only once and the broken src was never refreshed — the test fails.
 */
import * as React from "react";

import { act, fireEvent, render, waitFor } from "@testing-library/react";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { beforeEach, describe, expect, it, vi } from "vitest";

import type { Card, CardImage, Deck } from "@/lib/types";

// dnd-kit's DndContext renders the card list inertly here.
vi.mock("@dnd-kit/core", async () => {
  const actual = await vi.importActual<typeof import("@dnd-kit/core")>(
    "@dnd-kit/core",
  );
  return {
    ...actual,
    DndContext: ({ children }: { children: React.ReactNode }) => (
      <div data-testid="dnd-context">{children}</div>
    ),
  };
});

// --- Mock the data-access + auth modules -----------------------------------
const getDeck = vi.fn();
const listCards = vi.fn();
const reorderCards = vi.fn();
const createCard = vi.fn();
const listCardImages = vi.fn();
const imageDisplayUrl = vi.fn();

vi.mock("@/features/cards/cardApi", () => ({
  listCards: (...args: unknown[]) => listCards(...args),
  reorderCards: (...args: unknown[]) => reorderCards(...args),
  createCard: (...args: unknown[]) => createCard(...args),
}));

vi.mock("@/features/decks/deckApi", () => ({
  getDeck: (...args: unknown[]) => getDeck(...args),
  duplicateDeck: vi.fn(),
  renameDeck: vi.fn(),
  softDeleteDeck: vi.fn(),
}));

vi.mock("@/features/images/imageApi", () => ({
  imageDisplayUrl: (...args: unknown[]) => imageDisplayUrl(...args),
  listCardImages: (...args: unknown[]) => listCardImages(...args),
}));

vi.mock("@/features/auth/AuthContext", () => ({
  clearAuthOnUnauthorized: vi.fn(),
}));

vi.mock("@/components/ui/use-toast", () => ({
  toast: vi.fn(),
}));

import DeckDetailPage from "@/features/decks/DeckDetailPage";

const DECK: Deck = {
  id: "deck1",
  owner: "u1",
  name: "Shoot",
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
  created: "",
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

beforeEach(() => {
  getDeck.mockReset();
  getDeck.mockResolvedValue(DECK);
  listCards.mockReset();
  listCards.mockResolvedValue([CARD]);
  reorderCards.mockReset();
  createCard.mockReset();
  listCardImages.mockReset();
  listCardImages.mockResolvedValue([IMAGE]);
  imageDisplayUrl.mockReset();
});

describe("DeckDetailPage thumbnail token refresh (react-2)", () => {
  it("re-mints the thumbnail URL when an <img> fails to load (expired token)", async () => {
    // First resolution returns a URL with an (about-to-expire) token; the
    // refresh after onError returns a URL with a fresh token.
    imageDisplayUrl
      .mockResolvedValueOnce("/api/files/card_images/img1/photo.jpg?token=stale")
      .mockResolvedValueOnce("/api/files/card_images/img1/photo.jpg?token=fresh");

    let container!: HTMLElement;
    await act(async () => {
      ({ container } = renderPage());
    });

    const getImg = () =>
      container.querySelector("img") as HTMLImageElement | null;
    await waitFor(() =>
      expect(getImg()?.getAttribute("src")).toContain("token=stale"),
    );
    expect(imageDisplayUrl).toHaveBeenCalledTimes(1);

    // Simulate the browser failing to load the expired-token URL.
    await act(async () => {
      fireEvent.error(getImg()!);
    });

    // The handler must re-resolve the URL (new token) and update the src.
    await waitFor(() => expect(imageDisplayUrl).toHaveBeenCalledTimes(2));
    await waitFor(() =>
      expect(getImg()?.getAttribute("src")).toContain("token=fresh"),
    );
  });

  it("does not loop forever if the refreshed URL still fails", async () => {
    // Both resolutions return the same URL (e.g. a genuine 404, not expiry):
    // the guard must stop re-minting once the src no longer changes.
    imageDisplayUrl.mockResolvedValue(
      "/api/files/card_images/img1/photo.jpg?token=same",
    );

    let container!: HTMLElement;
    await act(async () => {
      ({ container } = renderPage());
    });

    const getImg = () =>
      container.querySelector("img") as HTMLImageElement | null;
    await waitFor(() => expect(imageDisplayUrl).toHaveBeenCalledTimes(1));
    await waitFor(() => expect(getImg()).not.toBeNull());

    // First error triggers one refresh attempt; since the URL is unchanged the
    // state is not updated, so React does not re-fire error in a loop.
    await act(async () => {
      fireEvent.error(getImg()!);
    });
    await waitFor(() => expect(imageDisplayUrl).toHaveBeenCalledTimes(2));

    // A subsequent error attempts one more refresh but still no loop/state churn.
    await act(async () => {
      fireEvent.error(getImg()!);
    });
    await waitFor(() => expect(imageDisplayUrl).toHaveBeenCalledTimes(3));
  });
});
