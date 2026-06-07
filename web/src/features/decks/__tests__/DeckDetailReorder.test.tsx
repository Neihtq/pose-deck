/**
 * Regression test for the optimistic-reorder serialization (finding C3).
 *
 * `DeckDetailPage` reorders cards by writing the new positions to Dexie + the
 * outbox via `reorderCards`; the live card query re-renders the new order, so
 * there is no local optimistic snapshot to revert. We still serialize reorders
 * (a second drop is ignored while one is in flight) so two restripes can't
 * interleave, and a failed reorder surfaces a destructive toast (the live query
 * is the reconciliation path — a rollback/resync corrects the local order).
 *
 * `DndContext` is mocked so the test can invoke the captured `onDragEnd`
 * directly (driving real dnd-kit pointer drags under jsdom is impractical);
 * the rest of `@dnd-kit/core` and all of `@dnd-kit/sortable` (including the real
 * `arrayMove`) are kept intact.
 */
import * as React from "react";

import { act, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { db } from "@/lib/db";
import type { Card, Deck } from "@/lib/types";

// --- Capture the DndContext onDragEnd handler ------------------------------
let capturedOnDragEnd: ((event: unknown) => void) | null = null;

vi.mock("@dnd-kit/core", async () => {
  const actual = await vi.importActual<typeof import("@dnd-kit/core")>(
    "@dnd-kit/core",
  );
  return {
    ...actual,
    DndContext: ({
      children,
      onDragEnd,
    }: {
      children: React.ReactNode;
      onDragEnd: (event: unknown) => void;
    }) => {
      capturedOnDragEnd = onDragEnd;
      return <div data-testid="dnd-context">{children}</div>;
    },
  };
});

// --- Mock the data-access + auth modules -----------------------------------
const reorderCards = vi.fn();
const createCard = vi.fn();

vi.mock("@/features/cards/cardApi", () => ({
  reorderCards: (...args: unknown[]) => reorderCards(...args),
  createCard: (...args: unknown[]) => createCard(...args),
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

const toast = vi.fn();
vi.mock("@/components/ui/use-toast", () => ({
  toast: (...args: unknown[]) => toast(...args),
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

/** A controllable deferred promise so we can keep a request "in flight". */
function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (reason?: unknown) => void;
  const promise = new Promise<T>((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
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

/** Helper: build a fake DragEndEvent for the mocked DndContext. */
function dragEvent(activeId: string, overId: string) {
  return { active: { id: activeId }, over: { id: overId } };
}

beforeEach(async () => {
  capturedOnDragEnd = null;
  reorderCards.mockReset().mockResolvedValue(undefined);
  createCard.mockReset();
  toast.mockReset();
  await Promise.all([db.decks.clear(), db.cards.clear(), db.card_images.clear()]);
  // Initial local order: a, b, c.
  await db.decks.put(DECK);
  await db.cards.bulkPut([
    makeCard("a", 1000),
    makeCard("b", 2000),
    makeCard("c", 3000),
  ]);
});

describe("DeckDetailPage reorder (C3)", () => {
  it("ignores a second drop while the first reorder is still in flight", async () => {
    const first = deferred<void>();
    reorderCards.mockReturnValueOnce(first.promise);

    renderPage();
    // Wait for the live card query to render the rows.
    await screen.findByText("a");
    await waitFor(() => expect(capturedOnDragEnd).not.toBeNull());

    // First drag: move "a" after "b" -> [b, a, c]. Request stays pending.
    act(() => {
      capturedOnDragEnd!(dragEvent("a", "b"));
    });
    expect(reorderCards).toHaveBeenCalledTimes(1);
    expect(reorderCards.mock.calls[0][1]).toEqual(["b", "a", "c"]);

    // Second drag committed BEFORE the first resolves must be ignored, so we
    // never stack a second reorder on an unconfirmed one.
    act(() => {
      capturedOnDragEnd!(dragEvent("c", "a"));
    });
    expect(reorderCards).toHaveBeenCalledTimes(1);

    // Let the first request settle; reorders are accepted again afterwards.
    await act(async () => {
      first.resolve();
      await first.promise;
      await new Promise((r) => setTimeout(r, 0));
    });

    act(() => {
      capturedOnDragEnd!(dragEvent("c", "b"));
    });
    expect(reorderCards).toHaveBeenCalledTimes(2);
  });

  it("surfaces a destructive toast when the reorder write fails", async () => {
    const failing = deferred<void>();
    reorderCards.mockReturnValueOnce(failing.promise);

    renderPage();
    await screen.findByText("a");
    await waitFor(() => expect(capturedOnDragEnd).not.toBeNull());

    act(() => {
      capturedOnDragEnd!(dragEvent("a", "b"));
    });
    expect(reorderCards).toHaveBeenCalledTimes(1);

    await act(async () => {
      failing.reject(new Error("network"));
      await failing.promise.catch(() => {});
    });

    await waitFor(() =>
      expect(toast).toHaveBeenCalledWith(
        expect.objectContaining({ variant: "destructive" }),
      ),
    );
  });
});
