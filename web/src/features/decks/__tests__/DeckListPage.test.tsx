/**
 * Component tests for DeckListPage (route: "/", DESIGN.md §3.3).
 *
 * As of M3 the deck list is local-first: decks are read from Dexie via a live
 * query. These tests seed the real (fake-indexeddb) `db` and let the live query
 * drive the UI; mutations are mocked at the deckApi function level, and the
 * delete mock mirrors a real soft-delete into Dexie so we can assert the live
 * query drops the row (the M1 "refetch + toast" behaviour, now via live query).
 *
 * The real `deckGrouping` is kept so we exercise the actual grouping/search
 * logic. `useNavigate` is spied through a partial react-router-dom mock.
 */
import { fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { db } from "@/lib/db";
import type { Deck } from "@/lib/types";

const navigate = vi.fn();
vi.mock("react-router-dom", async () => {
  const actual =
    await vi.importActual<typeof import("react-router-dom")>(
      "react-router-dom",
    );
  return { ...actual, useNavigate: () => navigate };
});

const createDeck = vi.fn();
const duplicateDeck = vi.fn();
const softDeleteDeck = vi.fn();
const renameDeck = vi.fn();
vi.mock("@/features/decks/deckApi", () => ({
  createDeck: (...a: unknown[]) => createDeck(...a),
  duplicateDeck: (...a: unknown[]) => duplicateDeck(...a),
  softDeleteDeck: (...a: unknown[]) => softDeleteDeck(...a),
  renameDeck: (...a: unknown[]) => renameDeck(...a),
}));

// Thumbnails are best-effort; stub the URL resolver so the page's thumbnail
// effect never hits a real backend. (liveCards/liveCardImages read the real,
// empty db, so no images resolve.)
vi.mock("@/features/images/imageApi", () => ({
  imageDisplayUrl: vi.fn(async () => null),
}));

vi.mock("@/features/auth/AuthContext", () => ({
  clearAuthOnUnauthorized: vi.fn(() => false),
}));

const toast = vi.fn();
vi.mock("@/components/ui/use-toast", () => ({
  toast: (...a: unknown[]) => toast(...a),
}));

import DeckListPage from "@/features/decks/DeckListPage";
import { ThemeProvider } from "@/components/theme/ThemeProvider";

function makeDeck(overrides: Partial<Deck> & { id: string; name: string }): Deck {
  return {
    owner: "u1",
    shoot_date: "",
    client_updated_at: "",
    created: "",
    updated: "",
    deleted_at: "",
    ...overrides,
  };
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

// Two days in the future / past, relative to the test run, as ISO strings so
// grouping (Upcoming / Past) is deterministic regardless of when tests run.
function isoOffsetDays(days: number): string {
  const d = new Date();
  d.setDate(d.getDate() + days);
  return d.toISOString();
}

beforeEach(async () => {
  navigate.mockReset();
  createDeck.mockReset();
  duplicateDeck.mockReset();
  softDeleteDeck.mockReset();
  renameDeck.mockReset();
  toast.mockReset();
  await Promise.all([db.decks.clear(), db.cards.clear(), db.card_images.clear()]);
});

describe("DeckListPage", () => {
  it("shows a loading state, then renders decks grouped by date", async () => {
    await db.decks.bulkPut([
      makeDeck({ id: "u", name: "Future Shoot", shoot_date: isoOffsetDays(2) }),
      makeDeck({ id: "n", name: "No Date Shoot" }),
      makeDeck({ id: "p", name: "Old Shoot", shoot_date: isoOffsetDays(-5) }),
    ]);

    renderPage();

    await screen.findByText("Future Shoot");
    expect(screen.getByText("No Date Shoot")).toBeInTheDocument();
    expect(screen.getByText("Old Shoot")).toBeInTheDocument();
    // Section headers from grouping.
    expect(screen.getByText("Upcoming")).toBeInTheDocument();
    expect(screen.getByText("Undated")).toBeInTheDocument();
    expect(screen.getByText("Past")).toBeInTheDocument();
  });

  it("renders the empty state when there are no decks", async () => {
    renderPage();
    await screen.findByText(/no decks yet/i);
  });

  it("filters decks by the search query", async () => {
    await db.decks.bulkPut([
      makeDeck({ id: "a", name: "Smith Wedding" }),
      makeDeck({ id: "b", name: "Jones Portraits" }),
    ]);
    renderPage();
    await screen.findByText("Smith Wedding");

    fireEvent.change(screen.getByLabelText("Search decks by name"), {
      target: { value: "jones" },
    });

    expect(screen.queryByText("Smith Wedding")).not.toBeInTheDocument();
    expect(screen.getByText("Jones Portraits")).toBeInTheDocument();
  });

  it("shows a no-match message when the search filters everything out", async () => {
    await db.decks.put(makeDeck({ id: "a", name: "Smith Wedding" }));
    renderPage();
    await screen.findByText("Smith Wedding");

    fireEvent.change(screen.getByLabelText("Search decks by name"), {
      target: { value: "zzz" },
    });
    expect(screen.getByText(/no decks match/i)).toBeInTheDocument();
  });

  it("creates a deck via the dialog and navigates into it", async () => {
    createDeck.mockResolvedValue(makeDeck({ id: "new1", name: "Beach Shoot" }));
    renderPage();
    await screen.findByText(/no decks yet/i);

    // Open the dialog from the header button.
    fireEvent.click(
      screen.getAllByRole("button", { name: /new deck/i })[0],
    );

    const nameInput = await screen.findByLabelText("Name");
    const dialog = nameInput.closest("form") as HTMLFormElement;
    const submit = within(dialog).getByRole("button", { name: "Create deck" });

    // Validation: submit is disabled while the name is empty.
    expect(submit).toBeDisabled();

    fireEvent.change(nameInput, { target: { value: "Beach Shoot" } });
    expect(submit).toBeEnabled();

    fireEvent.click(submit);

    await waitFor(() =>
      expect(createDeck).toHaveBeenCalledWith(
        expect.objectContaining({ name: "Beach Shoot" }),
      ),
    );
    await waitFor(() =>
      expect(navigate).toHaveBeenCalledWith("/decks/new1"),
    );
  });

  it("optimistically deletes a deck: the live query drops the row and toasts", async () => {
    await db.decks.put(makeDeck({ id: "d1", name: "Doomed Deck" }));
    // The mock mirrors a real soft-delete into Dexie so the live query updates.
    softDeleteDeck.mockImplementation(async (id: string) => {
      await db.decks.update(id, { deleted_at: new Date().toISOString() });
    });

    renderPage();
    await screen.findByText("Doomed Deck");

    // Open the deck's actions dropdown and click Delete → confirm in the dialog.
    fireEvent.pointerDown(
      screen.getByRole("button", { name: "Deck actions for Doomed Deck" }),
      new window.PointerEvent("pointerdown", { button: 0, bubbles: true }),
    );
    const menu = await screen.findByRole("menu");
    fireEvent.click(within(menu).getByText("Delete"));

    const confirm = await screen.findByRole("alertdialog");
    fireEvent.click(within(confirm).getByRole("button", { name: "Delete" }));

    await waitFor(() => expect(softDeleteDeck).toHaveBeenCalledWith("d1"));
    await waitFor(() =>
      expect(screen.queryByText("Doomed Deck")).not.toBeInTheDocument(),
    );
    await waitFor(() =>
      expect(toast).toHaveBeenCalledWith(
        expect.objectContaining({ title: "Deck moved to Trash" }),
      ),
    );
  });
});
