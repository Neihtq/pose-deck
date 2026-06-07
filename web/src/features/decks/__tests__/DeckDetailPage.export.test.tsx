/**
 * Component test for the "Export as PDF" action in the deck detail header
 * dropdown. The export module (`@/features/export/exportDeckPdf`) is MOCKED so
 * no real PDF / canvas / download runs — jsdom lacks the canvas + Blob plumbing
 * the React-PDF browser path and the download anchor rely on (those are covered
 * by manual / Playwright verification). Here we assert the WIRING: selecting the
 * item calls `exportDeckPdf` with the deck id, the item shows a loading state
 * while pending and resets after, and a rejection surfaces a destructive toast.
 */
import { fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { db } from "@/lib/db";
import type { Deck } from "@/lib/types";

const navigate = vi.fn();
vi.mock("react-router-dom", async () => {
  const actual = await vi.importActual<typeof import("react-router-dom")>("react-router-dom");
  return { ...actual, useNavigate: () => navigate };
});

vi.mock("@/features/cards/cardApi", () => ({
  reorderCards: vi.fn(),
  createCard: vi.fn(),
  softDeleteCard: vi.fn(),
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
  clearAuthOnUnauthorized: vi.fn(() => false),
  useAuth: () => ({ user: { id: "u1", email: "owner@posedeck.test" } }),
}));
vi.mock("@/features/decks/ShareDeckDialog", () => ({
  ShareDeckDialog: () => null,
}));
const toast = vi.fn();
vi.mock("@/components/ui/use-toast", () => ({
  toast: (...a: unknown[]) => toast(...a),
}));

// The export module is loaded via dynamic import in the handler; mock it.
const exportDeckPdf = vi.fn();
vi.mock("@/features/export/exportDeckPdf", () => ({
  exportDeckPdf: (...a: unknown[]) => exportDeckPdf(...a),
}));

import DeckDetailPage from "@/features/decks/DeckDetailPage";

const DECK: Deck = {
  id: "deck1",
  owner: "u1",
  name: "Smith Wedding",
  shoot_date: "",
  client_updated_at: "",
  created: "",
  updated: "",
  deleted_at: "",
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

async function openExportItem(): Promise<HTMLElement> {
  fireEvent.pointerDown(
    screen.getByRole("button", { name: "Deck options" }),
    new window.PointerEvent("pointerdown", { button: 0, bubbles: true }),
  );
  const menu = await screen.findByRole("menu");
  return within(menu).getByTestId("export-pdf");
}

beforeEach(async () => {
  navigate.mockReset();
  toast.mockReset();
  exportDeckPdf.mockReset();
  await Promise.all([db.decks.clear(), db.cards.clear(), db.card_images.clear()]);
  await db.decks.put(DECK);
});

describe("DeckDetailPage — Export as PDF", () => {
  it("calls exportDeckPdf with the deck id and toasts success", async () => {
    exportDeckPdf.mockResolvedValue({ fileName: "Smith Wedding.pdf", droppedImages: 0 });
    renderPage();
    await screen.findByText("Smith Wedding");

    fireEvent.click(await openExportItem());

    await waitFor(() =>
      expect(exportDeckPdf).toHaveBeenCalledWith("deck1", expect.objectContaining({ db })),
    );
    await waitFor(() =>
      expect(toast).toHaveBeenCalledWith(expect.objectContaining({ title: "PDF exported" })),
    );
  });

  it("shows 'Exporting…' / disabled while pending, then resets on resolve", async () => {
    let resolveExport!: (v: { fileName: string; droppedImages: number }) => void;
    exportDeckPdf.mockImplementation(
      () => new Promise((res) => { resolveExport = res; }),
    );
    renderPage();
    await screen.findByText("Smith Wedding");

    fireEvent.click(await openExportItem());

    // While pending the (re-opened) menu item flips to "Exporting…" and disables.
    await waitFor(() => {
      const item = screen.getByTestId("export-pdf");
      expect(item).toHaveTextContent("Exporting…");
      expect(item).toHaveAttribute("aria-disabled", "true");
    });

    resolveExport({ fileName: "Smith Wedding.pdf", droppedImages: 0 });

    await waitFor(() =>
      expect(screen.getByTestId("export-pdf")).toHaveTextContent("Export as PDF"),
    );
  });

  it("warns about omitted images when some drop out", async () => {
    exportDeckPdf.mockResolvedValue({ fileName: "Smith Wedding.pdf", droppedImages: 2 });
    renderPage();
    await screen.findByText("Smith Wedding");

    fireEvent.click(await openExportItem());

    await waitFor(() =>
      expect(toast).toHaveBeenCalledWith(
        expect.objectContaining({
          title: "PDF exported",
          description: expect.stringContaining("2 images unavailable"),
        }),
      ),
    );
  });

  it("shows a destructive toast and clears busy on rejection", async () => {
    exportDeckPdf.mockRejectedValue(new Error("boom"));
    renderPage();
    await screen.findByText("Smith Wedding");

    fireEvent.click(await openExportItem());

    await waitFor(() =>
      expect(toast).toHaveBeenCalledWith(
        expect.objectContaining({ variant: "destructive", title: "Export failed" }),
      ),
    );
    // Busy cleared: re-opening the menu shows the idle label again.
    await waitFor(() =>
      expect(screen.getByTestId("export-pdf")).toHaveTextContent("Export as PDF"),
    );
  });
});
