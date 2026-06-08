/**
 * Regression test for finding react-1: card image display URLs embed a
 * short-lived `?token=` (FILE_TOKEN_TTL_MS ≈ 90s in pocketbase.ts) minted once
 * by the resolve effect, which only re-runs when `images` changes. On a
 * long-lived editor session the token expires, so any browser re-fetch of an
 * already-rendered thumbnail (lazy reveal, cache eviction, reconnect) requests
 * `/api/files/...?token=<expired>` and PocketBase rejects it — the thumbnail
 * breaks and is never recovered.
 *
 * The fix adds an `onError` handler that re-mints the display URL (fresh token)
 * for the failing image. This test renders the editor in edit mode with one
 * image, fires the <img> `error` event (simulating an expired-token 4xx), and
 * asserts the URL is re-resolved and the `src` updated to the new-token URL.
 *
 * Before the fix there is no onError handler, so imageDisplayUrl is called only
 * once and the broken src is never refreshed — the test fails.
 */
import { act, fireEvent, render, waitFor } from "@testing-library/react";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { db } from "@/lib/db";
import type { Card, CardImage, Deck } from "@/lib/types";

// --- Mock data-access + side-effect modules -------------------------------
// The card + its images are read from Dexie; only the URL resolver is mocked.
const imageDisplayUrl = vi.fn();

vi.mock("@/features/cards/cardApi", () => ({
  createCard: vi.fn(),
  updateCard: vi.fn(),
  softDeleteCard: vi.fn(),
}));

vi.mock("@/features/images/imageApi", () => ({
  MAX_IMAGES_PER_CARD: 5,
  deleteCardImage: vi.fn(),
  imageDisplayUrl: (...args: unknown[]) => imageDisplayUrl(...args),
}));

vi.mock("@/features/images/useImageUpload", () => ({
  useImageUpload: () => ({
    upload: vi.fn(),
    pasteHandler: vi.fn(),
    uploading: false,
    error: null,
  }),
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

const CARD: Card = {
  id: "card1",
  deck: "deck1",
  position: 1000,
  title: "Shot",
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
  imageDisplayUrl.mockReset();
  await Promise.all([
    db.decks.clear(),
    db.cards.clear(),
    db.card_images.clear(),
  ]);
  await db.decks.put(DECK);
  await db.cards.put(CARD);
  await db.card_images.put(IMAGE);
});

describe("CardEditor image token refresh (react-1)", () => {
  it("re-mints the display URL when a thumbnail fails to load (expired token)", async () => {
    // First resolution returns a URL with an (about-to-expire) token; the
    // refresh after onError returns a URL with a fresh token.
    imageDisplayUrl
      .mockResolvedValueOnce("/api/files/card_images/img1/photo.jpg?token=stale")
      .mockResolvedValueOnce("/api/files/card_images/img1/photo.jpg?token=fresh");

    let container!: HTMLElement;
    await act(async () => {
      ({ container } = renderEditPage());
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
      ({ container } = renderEditPage());
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
