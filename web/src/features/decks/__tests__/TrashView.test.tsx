/**
 * Component tests for TrashView (route: "/trash", DESIGN.md §3.3).
 *
 * Covers: initial loading state, load error + retry, the empty state, rendering
 * a soft-deleted deck, and the optimistic restore flow (the row disappears and
 * a success toast fires). `deckApi` and the auth 401-handler are mocked, so no
 * PocketBase SDK or network is involved.
 */
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { beforeEach, describe, expect, it, vi } from "vitest";

import type { Deck } from "@/lib/types";

const listTrashedDecks = vi.fn();
const restoreDeck = vi.fn();
vi.mock("@/features/decks/deckApi", () => ({
  listTrashedDecks: (...a: unknown[]) => listTrashedDecks(...a),
  restoreDeck: (...a: unknown[]) => restoreDeck(...a),
}));

vi.mock("@/features/auth/AuthContext", () => ({
  clearAuthOnUnauthorized: vi.fn(() => false),
}));

const toast = vi.fn();
vi.mock("@/components/ui/use-toast", () => ({
  toast: (...a: unknown[]) => toast(...a),
}));

import TrashView from "@/features/decks/TrashView";

function makeDeck(id: string, name: string): Deck {
  return {
    id,
    owner: "u1",
    name,
    shoot_date: "",
    client_updated_at: "",
    created: "",
    updated: "",
    deleted_at: "2026-06-01T10:00:00.000Z",
  };
}

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((res) => {
    resolve = res;
  });
  return { promise, resolve };
}

function renderView() {
  return render(
    <MemoryRouter>
      <TrashView />
    </MemoryRouter>,
  );
}

beforeEach(() => {
  listTrashedDecks.mockReset();
  restoreDeck.mockReset();
  toast.mockReset();
});

describe("TrashView", () => {
  it("shows a loading state, then the empty state when trash is empty", async () => {
    listTrashedDecks.mockResolvedValue([]);
    renderView();
    expect(screen.getByText("Loading Trash…")).toBeInTheDocument();
    await screen.findByText("Trash is empty.");
  });

  it("renders trashed decks", async () => {
    listTrashedDecks.mockResolvedValue([
      makeDeck("d1", "Cancelled Wedding"),
    ]);
    renderView();
    await screen.findByText("Cancelled Wedding");
    expect(
      screen.getByRole("button", { name: "Restore" }),
    ).toBeInTheDocument();
  });

  it("shows a load error with a Retry that refetches", async () => {
    listTrashedDecks.mockRejectedValueOnce(new Error("boom"));
    renderView();
    await screen.findByText(/could not load trash/i);

    listTrashedDecks.mockResolvedValueOnce([makeDeck("d1", "Recovered")]);
    fireEvent.click(screen.getByRole("button", { name: "Retry" }));
    await screen.findByText("Recovered");
  });

  it("restores a deck: removes the row and toasts", async () => {
    listTrashedDecks.mockResolvedValue([makeDeck("d1", "Bring Me Back")]);
    restoreDeck.mockResolvedValue(undefined);
    renderView();
    await screen.findByText("Bring Me Back");

    fireEvent.click(screen.getByRole("button", { name: "Restore" }));

    await waitFor(() => expect(restoreDeck).toHaveBeenCalledWith("d1"));
    await waitFor(() =>
      expect(screen.queryByText("Bring Me Back")).not.toBeInTheDocument(),
    );
    expect(toast).toHaveBeenCalledWith(
      expect.objectContaining({ title: "Deck restored" }),
    );
  });

  it("disables the row's button while a restore is in flight", async () => {
    listTrashedDecks.mockResolvedValue([makeDeck("d1", "Pending Restore")]);
    const pending = deferred<void>();
    restoreDeck.mockReturnValue(pending.promise);
    renderView();
    await screen.findByText("Pending Restore");

    fireEvent.click(screen.getByRole("button", { name: "Restore" }));
    const busy = await screen.findByRole("button", { name: "Restoring…" });
    expect(busy).toBeDisabled();

    pending.resolve();
    await waitFor(() =>
      expect(screen.queryByText("Pending Restore")).not.toBeInTheDocument(),
    );
  });
});
