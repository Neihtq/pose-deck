/**
 * Regression test for the optimistic-reorder revert race (finding C3).
 *
 * `DeckDetailPage` reorders cards optimistically and persists with
 * `reorderCards`. The original implementation captured the pre-drag card list
 * as a local revert snapshot and restored it on failure. Under overlapping
 * drags (a second drop committed before the first request settled) that
 * snapshot was an intermediate, non-server-confirmed order, so a later failure
 * could restore a stale ordering that diverged from the server.
 *
 * The fix serializes reorders (a second drop is ignored while one is in flight)
 * and, on failure, re-fetches the authoritative order via `listCards` instead
 * of trusting a local snapshot. These tests exercise both behaviours.
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
const getDeck = vi.fn();
const listCards = vi.fn();
const reorderCards = vi.fn();
const createCard = vi.fn();

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
  imageDisplayUrl: vi.fn(async () => null),
  listCardImages: vi.fn(async () => []),
}));

vi.mock("@/features/auth/AuthContext", () => ({
  clearAuthOnUnauthorized: vi.fn(),
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

beforeEach(() => {
  capturedOnDragEnd = null;
  getDeck.mockReset().mockResolvedValue(DECK);
  reorderCards.mockReset().mockResolvedValue(undefined);
  createCard.mockReset();
  toast.mockReset();
  // Initial server order: a, b, c.
  listCards
    .mockReset()
    .mockResolvedValue([
      makeCard("a", 1000),
      makeCard("b", 2000),
      makeCard("c", 3000),
    ]);
});

describe("DeckDetailPage reorder race (C3)", () => {
  it("ignores a second drop while the first reorder is still in flight", async () => {
    const first = deferred<void>();
    reorderCards.mockReturnValueOnce(first.promise);

    renderPage();
    // Wait for the load effect (deck + cards + thumbnails) to fully settle so
    // later state updates aren't attributed to un-acted async work.
    await screen.findByText("a");
    await waitFor(() => expect(capturedOnDragEnd).not.toBeNull());

    // First drag: move "a" after "b" -> [b, a, c]. Request stays pending.
    act(() => {
      capturedOnDragEnd!(dragEvent("a", "b"));
    });
    expect(reorderCards).toHaveBeenCalledTimes(1);
    expect(reorderCards.mock.calls[0][1]).toEqual(["b", "a", "c"]);

    // Second drag committed BEFORE the first resolves must be ignored, so we
    // never stack an optimistic reorder on an unconfirmed one.
    act(() => {
      capturedOnDragEnd!(dragEvent("c", "a"));
    });
    expect(reorderCards).toHaveBeenCalledTimes(1);

    // Let the first request settle; reorders are accepted again afterwards.
    // Flush an extra task so the page's `.finally(setReordering(false))`
    // microtask runs inside this act() before we assert.
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

  it("re-fetches the authoritative order on failure instead of reverting to a local snapshot", async () => {
    const failing = deferred<void>();
    reorderCards.mockReturnValueOnce(failing.promise);

    // When the failed reorder triggers a re-fetch, the server reports a
    // DIFFERENT authoritative order than any local snapshot the client held.
    const serverTruth = [
      makeCard("c", 1000),
      makeCard("b", 2000),
      makeCard("a", 3000),
    ];

    renderPage();
    await screen.findByText("a");
    await waitFor(() => expect(capturedOnDragEnd).not.toBeNull());
    // Drain the initial load's listCards call(s) so the next resolution is ours.
    await waitFor(() => expect(listCards).toHaveBeenCalled());
    listCards.mockResolvedValueOnce(serverTruth);

    act(() => {
      capturedOnDragEnd!(dragEvent("a", "b"));
    });
    expect(reorderCards).toHaveBeenCalledTimes(1);

    const listCallsBeforeFailure = listCards.mock.calls.length;

    await act(async () => {
      failing.reject(new Error("network"));
      await failing.promise.catch(() => {});
    });

    // On failure the page MUST re-fetch authoritative order via listCards,
    // not silently revert to a captured local snapshot.
    await waitFor(() =>
      expect(listCards.mock.calls.length).toBeGreaterThan(
        listCallsBeforeFailure,
      ),
    );
    expect(toast).toHaveBeenCalledWith(
      expect.objectContaining({ variant: "destructive" }),
    );
  });
});
