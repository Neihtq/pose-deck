/**
 * Regression test for SPEC-1: deck-list tiles must render the deck
 * auto-thumbnail — the first image of the first (lowest-position) card
 * (DESIGN.md §3.3 "Auto-thumbnail (derived): First image of first card").
 *
 * As of M3 the join is local-first: `DeckListPage` reads cards/images from
 * Dexie (`liveCards` → `liveCardImages`) and resolves the display URL via
 * `imageDisplayUrl`. These tests seed the real (fake-indexeddb) `db` and assert
 * the resolved URL reaches an `<img>` tag, and that a deck with no image falls
 * back to a placeholder.
 */
import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { db } from "@/lib/db";
import { blobKey } from "@/lib/offlineKeys";
import type { Card, CardImage, Deck } from "@/lib/types";

const imageDisplayUrl = vi.fn();

vi.mock("@/features/decks/deckApi", () => ({
  createDeck: vi.fn(),
  duplicateDeck: vi.fn(),
  renameDeck: vi.fn(),
  softDeleteDeck: vi.fn(),
}));

vi.mock("@/features/images/imageApi", () => ({
  imageDisplayUrl: (...args: unknown[]) => imageDisplayUrl(...args),
}));

vi.mock("@/features/auth/AuthContext", () => ({
  clearAuthOnUnauthorized: vi.fn(() => false),
}));

vi.mock("@/components/ui/use-toast", () => ({
  toast: vi.fn(),
}));

import DeckListPage from "@/features/decks/DeckListPage";
import { ThemeProvider } from "@/components/theme/ThemeProvider";

function makeDeck(id: string, name: string): Deck {
  return {
    id,
    owner: "u1",
    name,
    shoot_date: "",
    client_updated_at: "",
    created: "",
    updated: "",
    deleted_at: "",
  };
}

function makeCard(id: string, deck: string, position: number): Card {
  return {
    id,
    deck,
    position,
    title: id,
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

function makeImage(id: string, card: string, position: number): CardImage {
  return { id, card, position, file: `${id}.jpg`, created: "" };
}

function renderPage() {
  return render(
    <ThemeProvider>
      <MemoryRouter>
        <DeckListPage />
      </MemoryRouter>
    </ThemeProvider>,
  );
}

beforeEach(async () => {
  imageDisplayUrl.mockReset();
  await Promise.all([
    db.decks.clear(),
    db.cards.clear(),
    db.card_images.clear(),
    db.image_blobs.clear(),
  ]);
});

describe("deck-list auto-thumbnail (DESIGN.md §3.3)", () => {
  it("renders the first image of the first card as the deck tile thumbnail", async () => {
    await db.decks.put(makeDeck("d1", "Smith Wedding"));
    // Two cards out of order; the lowest-position card (c-first) is the deck's
    // first card, and its lowest-position image is the auto-thumbnail.
    await db.cards.bulkPut([
      makeCard("c-first", "d1", 1000),
      makeCard("c-second", "d1", 2000),
    ]);
    await db.card_images.bulkPut([
      makeImage("img-a", "c-first", 1000),
      makeImage("img-b", "c-first", 2000),
    ]);
    imageDisplayUrl.mockResolvedValue("https://cdn.test/thumb-a.jpg");

    const { container } = renderPage();

    await screen.findByText("Smith Wedding");

    const img = await waitFor(() => {
      const found = container.querySelector("img");
      expect(found).not.toBeNull();
      return found as HTMLImageElement;
    });
    expect(img.getAttribute("src")).toBe("https://cdn.test/thumb-a.jpg");

    // Resolved the thumbnail from the FIRST card's first image (img-a).
    expect(imageDisplayUrl).toHaveBeenCalledWith(
      expect.objectContaining({ id: "img-a" }),
      expect.anything(),
    );
  });

  it("falls back to a placeholder when the deck has no card image", async () => {
    await db.decks.put(makeDeck("d2", "Empty Deck"));
    imageDisplayUrl.mockResolvedValue("should-not-be-used");

    const { container } = renderPage();

    await screen.findByText("Empty Deck");

    await screen.findByText("No image");
    expect(container.querySelector("img")).toBeNull();
    expect(imageDisplayUrl).not.toHaveBeenCalled();
  });
});

/**
 * Regression test for react-1: the deck-list tile thumbnail embeds a short-lived
 * `?token=` (FILE_TOKEN_TTL_MS ≈ 90s) resolved once into `thumbnails` state. On
 * a static/idle list the thumbnail effect (deps `[decks]`) never re-runs, so the
 * stored token is never refreshed; once it expires the protected file GET 404s
 * and the tile stays broken until a manual reload.
 *
 * The fix adds an `onError` on the tile <img> that asks the parent to re-resolve
 * a fresh-token URL once (guarded so an unchanged URL — a genuine 404 — can't
 * loop), mirroring <OfflineImage>'s onError re-mint used by deck detail / the
 * card editor. Before the fix the bare <img> had no onError, so the stale src
 * was never refreshed and these assertions fail.
 */
describe("deck-list thumbnail token refresh (react-1)", () => {
  it("re-mints the tile URL when the <img> fails to load (expired token)", async () => {
    await db.decks.put(makeDeck("d1", "Smith Wedding"));
    await db.cards.put(makeCard("c-first", "d1", 1000));
    await db.card_images.put(makeImage("img-a", "c-first", 1000));

    // First resolution → about-to-expire token; the post-onError refresh → fresh.
    imageDisplayUrl
      .mockResolvedValueOnce("https://cdn.test/thumb-a.jpg?token=stale")
      .mockResolvedValueOnce("https://cdn.test/thumb-a.jpg?token=fresh");

    const { container } = renderPage();
    await screen.findByText("Smith Wedding");

    const getImg = () =>
      container.querySelector("img") as HTMLImageElement | null;
    await waitFor(() =>
      expect(getImg()?.getAttribute("src")).toContain("token=stale"),
    );
    expect(imageDisplayUrl).toHaveBeenCalledTimes(1);

    // Simulate the browser failing the expired-token GET.
    await act(async () => {
      fireEvent.error(getImg()!);
    });

    // The parent must re-resolve (fresh token) and update the tile src.
    await waitFor(() => expect(imageDisplayUrl).toHaveBeenCalledTimes(2));
    await waitFor(() =>
      expect(getImg()?.getAttribute("src")).toContain("token=fresh"),
    );
  });

  it("does not loop when the re-resolved URL is unchanged (genuine 404)", async () => {
    await db.decks.put(makeDeck("d1", "Smith Wedding"));
    await db.cards.put(makeCard("c-first", "d1", 1000));
    await db.card_images.put(makeImage("img-a", "c-first", 1000));

    // Same URL every time (e.g. a real 404, not expiry): the guard must commit
    // no state change, so React does not re-fire error in a loop.
    imageDisplayUrl.mockResolvedValue("https://cdn.test/thumb-a.jpg?token=same");

    const { container } = renderPage();
    await screen.findByText("Smith Wedding");

    const getImg = () =>
      container.querySelector("img") as HTMLImageElement | null;
    await waitFor(() => expect(imageDisplayUrl).toHaveBeenCalledTimes(1));
    await waitFor(() => expect(getImg()).not.toBeNull());

    await act(async () => {
      fireEvent.error(getImg()!);
    });
    await waitFor(() => expect(imageDisplayUrl).toHaveBeenCalledTimes(2));

    // A second error attempts one more refresh but still no loop/state churn.
    await act(async () => {
      fireEvent.error(getImg()!);
    });
    await waitFor(() => expect(imageDisplayUrl).toHaveBeenCalledTimes(3));
  });
});

/**
 * Regression test for react-2: a pinned deck's home-screen tile thumbnail must
 * resolve from the offline `image_blobs` cache, not solely from the network
 * token URL. Before the fix the tile rendered a bare `<img src={imageDisplayUrl(...)}>`
 * (a network token URL), bypassing the pin that `<OfflineImage>`/`resolveImage`
 * consult — so offline a pinned deck showed the "No image" placeholder even
 * though the bytes were cached locally (contradicting DESIGN.md §2.2 pre-cache
 * intent and §5 "pre-cached deck + images work without connectivity").
 *
 * The fix passes the first `CardImage` record to `DeckCard`, which renders it
 * through `<OfflineImage>` (same as deck detail / the card editor). With a blob
 * pinned for the auto-thumbnail (first image of first card) under its
 * thumb-variant key, the tile must serve the cached blob's object URL and must
 * NOT consult the network resolver.
 */
describe("deck-list thumbnail offline pin (react-2)", () => {
  const created: string[] = [];

  beforeEach(() => {
    created.length = 0;
    // jsdom lacks the object-URL API; stub create/revoke on the URL global so
    // `<OfflineImage>` can mint (and later revoke) a blob URL for the pin. We do
    // NOT tear these down per-test: React flushes the unmount cleanup (which
    // calls revokeObjectURL) during teardown, after afterEach would have run.
    Object.assign(URL, {
      createObjectURL: vi.fn((_blob: Blob) => {
        const u = `blob:fake/${created.length}`;
        created.push(u);
        return u;
      }),
      revokeObjectURL: vi.fn(),
    });
  });

  it("serves the offline-pinned blob for the tile and never hits the network", async () => {
    await db.decks.put(makeDeck("d1", "Pinned Wedding"));
    await db.cards.put(makeCard("c-first", "d1", 1000));
    const firstImage = makeImage("img-a", "c-first", 1000);
    await db.card_images.put(firstImage);

    // Pin the auto-thumbnail bytes under the SAME thumb variant the tile
    // requests ("400x300"). resolveImage must find this and skip the network.
    await db.image_blobs.put({
      key: blobKey(firstImage, firstImage.file, { thumb: "400x300" }),
      card: firstImage.card,
      recordId: firstImage.id,
      blob: new Blob(["pinned-bytes"], { type: "image/jpeg" }),
      cachedAt: 0,
    });

    // If the pin is bypassed, the tile would mint a network token URL here.
    imageDisplayUrl.mockResolvedValue("https://cdn.test/network-token.jpg");

    const { container } = renderPage();
    await screen.findByText("Pinned Wedding");

    // The tile <img> renders the cached blob's object URL — proving the offline
    // pin was consulted (DESIGN.md §5 offline). Before the fix this was the
    // network token URL.
    const img = await waitFor(() => {
      const found = container.querySelector("img");
      expect(found).not.toBeNull();
      return found as HTMLImageElement;
    });
    expect(img.getAttribute("src")).toMatch(/^blob:fake\//);

    // The network resolver must NOT be consulted when the deck is pinned.
    expect(imageDisplayUrl).not.toHaveBeenCalled();
  });
});
