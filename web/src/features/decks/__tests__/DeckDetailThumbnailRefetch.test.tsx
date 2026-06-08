/**
 * Regression test for finding react-1: the deck-detail thumbnail-building effect
 * refetched every card's images on every live-query tick.
 *
 * The effect maps over the live `cards` list and calls `liveCardImages(db, id)`
 * for each card, then rebuilds the whole thumbnails map. It used to depend on
 * the `cards` array identity. Dexie's `useLiveQuery` hands back a NEW array
 * reference on every write to the cards table — including a reorder (which only
 * rewrites `position`) or a per-card field edit — so the effect re-fired and
 * re-queried images for ALL cards even when the set of cards was unchanged.
 *
 * The fix keys the effect off a stable string of card ids (`cardIdsKey`)
 * instead of the array identity, so a position-only or field-only cards-table
 * write no longer triggers a full image re-query. Adding/removing a card (which
 * changes the id set) still re-runs the effect.
 *
 * This test counts `liveCardImages` calls across a reorder write (no new
 * fetches expected after the fix) and across an add (a fresh fetch expected).
 * Before the fix the reorder assertion fails because every card is re-queried.
 */
import * as React from "react";

import { act, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { db } from "@/lib/db";
import type { Card, Deck } from "@/lib/types";

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

// Spy on `liveCardImages` while keeping `liveDeck` / `liveCards` real so the
// live queries still read from Dexie. The spy lets us count per-card image
// reads triggered by the thumbnail effect.
const liveCardImagesSpy = vi.fn();
vi.mock("@/lib/localStore", async () => {
  const actual =
    await vi.importActual<typeof import("@/lib/localStore")>("@/lib/localStore");
  return {
    ...actual,
    liveCardImages: (...args: Parameters<typeof actual.liveCardImages>) => {
      liveCardImagesSpy(...args);
      return actual.liveCardImages(...args);
    },
  };
});

vi.mock("@/features/cards/cardApi", () => ({
  reorderCards: vi.fn(),
  createCard: vi.fn(),
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
  clearAuthOnUnauthorized: vi.fn(),
  useAuth: () => ({ user: { id: "u1", email: "owner@posedeck.test" } }),
}));

vi.mock("@/features/decks/ShareDeckDialog", () => ({
  ShareDeckDialog: () => null,
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

function makeCard(id: string, position: number): Card {
  return {
    id,
    deck: "deck1",
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
  liveCardImagesSpy.mockReset();
  await Promise.all([
    db.decks.clear(),
    db.cards.clear(),
    db.card_images.clear(),
  ]);
  await db.decks.put(DECK);
  await db.cards.bulkPut([
    makeCard("a", 1000),
    makeCard("b", 2000),
    makeCard("c", 3000),
  ]);
});

describe("DeckDetailPage thumbnail refetch (react-1)", () => {
  it("does not re-query every card's images on a position-only cards-table write", async () => {
    await act(async () => {
      renderPage();
    });
    await screen.findByText("a");

    // Initial mount queries images once per card.
    await waitFor(() => expect(liveCardImagesSpy).toHaveBeenCalledTimes(3));
    liveCardImagesSpy.mockClear();

    // Simulate a reorder: a cards-table write that only rewrites `position`.
    // The live query re-resolves and hands the page a fresh `cards` array
    // reference, but the SET of card ids is unchanged.
    await act(async () => {
      await db.cards.bulkPut([
        makeCard("c", 500),
        makeCard("a", 1000),
        makeCard("b", 2000),
      ]);
      // Let the live query re-resolve and the effect (not) re-run.
      await new Promise((r) => setTimeout(r, 50));
    });

    // The new order must be reflected (live query re-rendered)...
    await waitFor(() => {
      const items = screen.getAllByText(/^[abc]$/);
      expect(items.map((n) => n.textContent)).toEqual(["c", "a", "b"]);
    });

    // ...but no card's images should have been re-queried, because the id set
    // did not change. Before the fix this is 3 (every card re-queried).
    expect(liveCardImagesSpy).toHaveBeenCalledTimes(0);
  });

  it("re-queries images when a new card is added (id set changes)", async () => {
    await act(async () => {
      renderPage();
    });
    await screen.findByText("a");
    await waitFor(() => expect(liveCardImagesSpy).toHaveBeenCalledTimes(3));
    liveCardImagesSpy.mockClear();

    await act(async () => {
      await db.cards.put(makeCard("d", 4000));
      await new Promise((r) => setTimeout(r, 50));
    });

    await screen.findByText("d");
    // The id set changed, so the effect re-runs and re-queries all four cards.
    await waitFor(() => expect(liveCardImagesSpy).toHaveBeenCalledTimes(4));
  });
});
