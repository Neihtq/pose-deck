/**
 * Regression test for finding react-3: CardEditor mutation handlers swallowed
 * 401s instead of clearing auth, leaving an expired session stuck on a failing
 * editor.
 *
 * Every peer page (DeckListPage, DeckDetailPage, TrashView) routes API errors
 * through `clearAuthOnUnauthorized(err)` so a rejected/expired token clears the
 * PocketBase auth store, which flips `isAuthenticated` false and lets
 * RequireAuth redirect to /login. CardEditor previously did NOT: handleSave,
 * handleDelete, handleDeleteImage and the load effect only surfaced a raw toast
 * or error message, so a 401 produced "Save failed / Please try again." forever
 * with no redirect.
 *
 * The fix wraps each catch with `if (clearAuthOnUnauthorized(err)) return;`
 * before showing the toast/error. These tests inject a 401 ClientResponseError
 * into each handler and assert clearAuthOnUnauthorized is invoked with it (and
 * the failure toast is suppressed). Before the fix the handler never calls
 * clearAuthOnUnauthorized, so these fail.
 */
import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { ClientResponseError } from "pocketbase";
import { beforeEach, describe, expect, it, vi } from "vitest";

import type { Card, CardImage } from "@/lib/types";

// --- Mock data-access + side-effect modules -------------------------------
const createCard = vi.fn();
const updateCard = vi.fn();
const softDeleteCard = vi.fn();
const deleteCardImage = vi.fn();
const listCardImages = vi.fn();
const imageDisplayUrl = vi.fn();
const getFirstListItem = vi.fn();
const toast = vi.fn();

// The unit under test: the real fix funnels errors here. We spy on it so we
// can assert it is consulted, while keeping its real "is this a 401?" logic.
const clearAuthOnUnauthorized = vi.fn();

vi.mock("@/features/cards/cardApi", () => ({
  createCard: (...args: unknown[]) => createCard(...args),
  updateCard: (...args: unknown[]) => updateCard(...args),
  softDeleteCard: (...args: unknown[]) => softDeleteCard(...args),
}));

vi.mock("@/features/images/imageApi", () => ({
  MAX_IMAGES_PER_CARD: 5,
  deleteCardImage: (...args: unknown[]) => deleteCardImage(...args),
  imageDisplayUrl: (...args: unknown[]) => imageDisplayUrl(...args),
  listCardImages: (...args: unknown[]) => listCardImages(...args),
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
    cards: () => ({
      getFirstListItem: (...args: unknown[]) => getFirstListItem(...args),
    }),
  },
}));

vi.mock("@/components/ui/use-toast", () => ({
  toast: (...args: unknown[]) => toast(...args),
}));

vi.mock("@/features/auth/AuthContext", () => ({
  clearAuthOnUnauthorized: (...args: unknown[]) =>
    clearAuthOnUnauthorized(...args),
}));

import CardEditor from "@/features/cards/CardEditor";

const CARD: Card = {
  id: "card1",
  collectionId: "c",
  collectionName: "cards",
  deck: "deck1",
  title: "Existing card",
  time_slot: "",
  subjects: "",
  direction: "",
  notes: "",
  position: 0,
  deleted_at: "",
  created: "",
  updated: "",
} as unknown as Card;

const IMAGE: CardImage = {
  id: "img1",
  collectionId: "ci",
  collectionName: "card_images",
  card: "card1",
  file: "f.jpg",
  position: 0,
  created: "",
  updated: "",
} as unknown as CardImage;

function unauthorized(): ClientResponseError {
  return new ClientResponseError({ status: 401, data: {} });
}

function renderEditPage() {
  return render(
    <MemoryRouter initialEntries={["/decks/deck1/cards/card1"]}>
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

beforeEach(() => {
  createCard.mockReset();
  updateCard.mockReset();
  softDeleteCard.mockReset();
  deleteCardImage.mockReset();
  listCardImages.mockReset();
  imageDisplayUrl.mockReset();
  getFirstListItem.mockReset();
  toast.mockReset();
  clearAuthOnUnauthorized.mockReset();
  // By default a 401 was indeed a 401 -> auth cleared, redirect handled.
  clearAuthOnUnauthorized.mockReturnValue(true);
  // Healthy edit-mode load by default.
  getFirstListItem.mockResolvedValue(CARD);
  listCardImages.mockResolvedValue([IMAGE]);
  imageDisplayUrl.mockResolvedValue("blob:img1");
});

async function waitForEditorLoaded() {
  await waitFor(() =>
    expect(
      screen.getByRole("button", { name: /^Save$/i }),
    ).toBeInTheDocument(),
  );
}

describe("CardEditor clears auth on 401 (react-3)", () => {
  it("routes a 401 from updateCard (save) through clearAuthOnUnauthorized", async () => {
    const err = unauthorized();
    updateCard.mockRejectedValue(err);

    renderEditPage();
    await waitForEditorLoaded();

    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: /^Save$/i }));
    });

    await waitFor(() =>
      expect(clearAuthOnUnauthorized).toHaveBeenCalledWith(err),
    );
    // The failure toast must be suppressed when auth was cleared.
    expect(
      toast.mock.calls.some((c) => c[0]?.title === "Save failed"),
    ).toBe(false);
  });

  it("routes a 401 from softDeleteCard (delete) through clearAuthOnUnauthorized", async () => {
    const err = unauthorized();
    softDeleteCard.mockRejectedValue(err);

    renderEditPage();
    await waitForEditorLoaded();

    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: /Delete/i }));
    });
    // Confirm in the dialog.
    await act(async () => {
      const dialogDelete = screen
        .getAllByRole("button", { name: /Delete/i })
        .at(-1)!;
      fireEvent.click(dialogDelete);
    });

    await waitFor(() =>
      expect(clearAuthOnUnauthorized).toHaveBeenCalledWith(err),
    );
    expect(
      toast.mock.calls.some((c) => c[0]?.title === "Delete failed"),
    ).toBe(false);
  });

  it("routes a 401 from deleteCardImage through clearAuthOnUnauthorized", async () => {
    const err = unauthorized();
    deleteCardImage.mockRejectedValue(err);

    renderEditPage();
    await waitForEditorLoaded();

    // Wait for the image thumbnail (and its remove button) to render.
    const removeBtn = await screen.findByRole("button", {
      name: /Remove image/i,
    });

    await act(async () => {
      fireEvent.click(removeBtn);
    });

    await waitFor(() =>
      expect(clearAuthOnUnauthorized).toHaveBeenCalledWith(err),
    );
    expect(
      toast.mock.calls.some((c) => c[0]?.title === "Could not remove image"),
    ).toBe(false);
  });

  it("routes a 401 from the load effect through clearAuthOnUnauthorized (no error message)", async () => {
    const err = unauthorized();
    getFirstListItem.mockRejectedValue(err);
    listCardImages.mockRejectedValue(err);

    renderEditPage();

    await waitFor(() =>
      expect(clearAuthOnUnauthorized).toHaveBeenCalledWith(err),
    );
    // With auth cleared, the editor must not show a raw load error.
    expect(
      screen.queryByText(/Failed to load card/i),
    ).not.toBeInTheDocument();
  });
});
