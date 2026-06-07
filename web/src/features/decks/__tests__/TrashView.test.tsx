/**
 * Component tests for TrashView (route: "/trash", DESIGN.md §3.3).
 *
 * As of M3 the trash view is local-first: soft-deleted decks are read from
 * Dexie via a live query. These tests seed the real (fake-indexeddb) `db` and
 * let the live query drive the UI; `restoreDeck` is mocked and mirrors a real
 * restore into Dexie so the live query drops the row.
 */
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { db } from "@/lib/db";
import type { Deck } from "@/lib/types";

const restoreDeck = vi.fn();
vi.mock("@/features/decks/deckApi", () => ({
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

beforeEach(async () => {
  restoreDeck.mockReset();
  toast.mockReset();
  await db.decks.clear();
});

describe("TrashView", () => {
  it("shows a loading state, then the empty state when trash is empty", async () => {
    renderView();
    await screen.findByText("Trash is empty.");
  });

  it("renders trashed decks", async () => {
    await db.decks.put(makeDeck("d1", "Cancelled Wedding"));
    renderView();
    await screen.findByText("Cancelled Wedding");
    expect(
      screen.getByRole("button", { name: "Restore" }),
    ).toBeInTheDocument();
  });

  it("restores a deck: the live query removes the row and toasts", async () => {
    await db.decks.put(makeDeck("d1", "Bring Me Back"));
    restoreDeck.mockImplementation(async (id: string) => {
      await db.decks.update(id, { deleted_at: "" });
    });
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
    await db.decks.put(makeDeck("d1", "Pending Restore"));
    const pending = deferred<void>();
    restoreDeck.mockReturnValue(pending.promise);
    renderView();
    await screen.findByText("Pending Restore");

    fireEvent.click(screen.getByRole("button", { name: "Restore" }));
    const busy = await screen.findByRole("button", { name: "Restoring…" });
    expect(busy).toBeDisabled();

    // Resolve + mirror the restore so the live query drops the row.
    await db.decks.update("d1", { deleted_at: "" });
    pending.resolve();
    await waitFor(() =>
      expect(screen.queryByText("Pending Restore")).not.toBeInTheDocument(),
    );
  });
});
