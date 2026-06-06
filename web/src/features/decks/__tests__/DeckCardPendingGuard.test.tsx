/**
 * Regression test for react-5: a deck's destructive actions must be guarded by
 * a per-deck "pending" state while a mutation for that deck is in flight, so a
 * user cannot re-fire a non-idempotent mutation (Duplicate) on the same deck
 * before the list refresh lands.
 *
 * Before the fix, DeckListPage.handleDuplicate/handleDelete had no per-deck
 * busy state and DeckCard exposed no `pending`/`disabled`. With a duplicate
 * request still in flight (the deck stays rendered because listDecks filters
 * out only soft-deleted decks), the dropdown could be reopened and Duplicate
 * clicked again, issuing a second non-idempotent duplicateDeck call.
 *
 * This test drives the real DeckCard's dropdown menu (with the jsdom pointer
 * polyfills Radix needs) and asserts:
 *   1. With `pending`, the Duplicate and Delete menu items are disabled and a
 *      click does NOT invoke the parent callbacks (no second mutation can fire).
 *   2. Without `pending`, the same items are enabled and DO invoke the callback.
 */
import { fireEvent, render, screen, within } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { beforeAll, beforeEach, describe, expect, it, vi } from "vitest";

import type { Deck } from "@/lib/types";

vi.mock("@/components/ui/use-toast", () => ({
  toast: vi.fn(),
}));

import { DeckCard } from "@/features/decks/DeckCard";

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

// Radix UI relies on PointerEvent + pointer-capture + scrollIntoView APIs that
// jsdom does not implement; polyfill them so the dropdown menu actually opens.
beforeAll(() => {
  if (typeof window.PointerEvent === "undefined") {
    class PointerEventPolyfill extends MouseEvent {
      public pointerId: number;
      public pointerType: string;
      constructor(type: string, params: PointerEventInit = {}) {
        super(type, params);
        this.pointerId = params.pointerId ?? 1;
        this.pointerType = params.pointerType ?? "mouse";
      }
    }
    // @ts-expect-error assigning a test polyfill onto the jsdom window
    window.PointerEvent = PointerEventPolyfill;
  }
  if (!Element.prototype.hasPointerCapture) {
    Element.prototype.hasPointerCapture = () => false;
  }
  if (!Element.prototype.setPointerCapture) {
    Element.prototype.setPointerCapture = () => {};
  }
  if (!Element.prototype.releasePointerCapture) {
    Element.prototype.releasePointerCapture = () => {};
  }
  if (!Element.prototype.scrollIntoView) {
    Element.prototype.scrollIntoView = () => {};
  }
});

const onDuplicate = vi.fn();
const onDelete = vi.fn();

beforeEach(() => {
  onDuplicate.mockReset();
  onDelete.mockReset();
});

function renderCard(pending: boolean) {
  const deck = makeDeck("d1", "Smith Wedding");
  render(
    <MemoryRouter>
      <DeckCard
        deck={deck}
        pending={pending}
        onOpen={() => {}}
        onRename={() => {}}
        onDuplicate={onDuplicate}
        onDelete={onDelete}
      />
    </MemoryRouter>,
  );
  // Open the actions dropdown. Radix opens the menu on pointerdown (primary
  // button); jsdom needs an explicit PointerEvent (polyfilled in beforeAll).
  const trigger = screen.getByRole("button", {
    name: "Deck actions for Smith Wedding",
  });
  fireEvent.pointerDown(
    trigger,
    new window.PointerEvent("pointerdown", { button: 0, bubbles: true }),
  );
}

describe("DeckCard per-deck pending guard (react-5)", () => {
  it("disables Duplicate/Delete and ignores clicks while the deck is pending", async () => {
    renderCard(true);

    const menu = await screen.findByRole("menu");
    const duplicateItem = within(menu).getByText("Duplicate");
    const deleteItem = within(menu).getByText("Delete");

    expect(
      duplicateItem.closest("[role='menuitem']")?.getAttribute("aria-disabled"),
    ).toBe("true");
    expect(
      deleteItem.closest("[role='menuitem']")?.getAttribute("aria-disabled"),
    ).toBe("true");

    // A click on a disabled item must NOT fire the parent mutation callback —
    // this is what prevents the duplicate non-idempotent request.
    fireEvent.click(duplicateItem);
    fireEvent.click(deleteItem);
    expect(onDuplicate).not.toHaveBeenCalled();
    expect(onDelete).not.toHaveBeenCalled();
  });

  it("invokes onDuplicate when the deck is not pending", async () => {
    renderCard(false);

    const menu = await screen.findByRole("menu");
    const duplicateItem = within(menu).getByText("Duplicate");

    expect(
      duplicateItem.closest("[role='menuitem']")?.getAttribute("aria-disabled"),
    ).not.toBe("true");

    fireEvent.click(duplicateItem);
    expect(onDuplicate).toHaveBeenCalledTimes(1);
  });
});
