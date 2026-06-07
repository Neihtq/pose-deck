/**
 * Component tests for ShareDeckDialog (M5 sharing).
 *
 * The guest list reads from the real (fake-indexeddb) `db` via a live query;
 * grantGuest/revokeGuest are mocked and mirror their effect into Dexie so the
 * live query propagates. Covers: render existing guests, add-by-email happy
 * path, not-found, duplicate blocked, self-share blocked, and revoke.
 */
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { db } from "@/lib/db";
import { newClientId } from "@/lib/ids";
import type { DeckGuest } from "@/lib/types";

const grantGuest = vi.fn();
const revokeGuest = vi.fn();
vi.mock("@/features/decks/guestApi", () => {
  class GuestNotFoundError extends Error {}
  return {
    grantGuest: (...a: unknown[]) => grantGuest(...a),
    revokeGuest: (...a: unknown[]) => revokeGuest(...a),
    GuestNotFoundError,
  };
});

// Re-import the mocked error class for use in test bodies.
import { GuestNotFoundError } from "@/features/decks/guestApi";

vi.mock("@/features/auth/AuthContext", () => ({
  clearAuthOnUnauthorized: vi.fn(() => false),
  useAuth: () => ({ user: { id: "owner1", email: "owner@posedeck.test" } }),
}));

const toast = vi.fn();
vi.mock("@/components/ui/use-toast", () => ({
  toast: (...a: unknown[]) => toast(...a),
}));

import { ShareDeckDialog } from "@/features/decks/ShareDeckDialog";

function renderDialog() {
  return render(
    <ShareDeckDialog deckId="deck1" open onOpenChange={() => {}} />,
  );
}

function makeGuest(id: string, user: string): DeckGuest {
  return { id, deck: "deck1", user, granted_at: "2026-06-07T00:00:00.000Z" };
}

beforeEach(async () => {
  grantGuest.mockReset();
  revokeGuest.mockReset();
  toast.mockReset();
  await Promise.all([db.deck_guests.clear()]);
});

describe("ShareDeckDialog", () => {
  it("renders the current guests", async () => {
    await db.deck_guests.put(makeGuest("g1", "guest-user-id"));
    renderDialog();
    await screen.findByText("guest-user-id");
    expect(screen.getByRole("button", { name: "Revoke" })).toBeInTheDocument();
  });

  it("shows the empty state when no guests", async () => {
    renderDialog();
    await screen.findByText("Not shared with anyone yet.");
  });

  it("shares by email (happy path) and toasts success", async () => {
    grantGuest.mockImplementation(async (deckId: string, email: string) => {
      const guest = makeGuest(newClientId(), "guest9");
      await db.deck_guests.put(guest);
      void deckId;
      void email;
      return guest;
    });
    renderDialog();
    await screen.findByText("Not shared with anyone yet.");

    fireEvent.change(screen.getByLabelText("Email"), {
      target: { value: "guest@posedeck.test" },
    });
    fireEvent.click(screen.getByRole("button", { name: "Share" }));

    await waitFor(() =>
      expect(grantGuest).toHaveBeenCalledWith("deck1", "guest@posedeck.test"),
    );
    await waitFor(() =>
      expect(toast).toHaveBeenCalledWith(
        expect.objectContaining({ title: "Deck shared" }),
      ),
    );
  });

  it("rejects a self-share without calling grantGuest", async () => {
    renderDialog();
    await screen.findByText("Not shared with anyone yet.");

    fireEvent.change(screen.getByLabelText("Email"), {
      target: { value: "owner@posedeck.test" },
    });
    fireEvent.click(screen.getByRole("button", { name: "Share" }));

    await waitFor(() =>
      expect(toast).toHaveBeenCalledWith(
        expect.objectContaining({ title: "Can't share with yourself" }),
      ),
    );
    expect(grantGuest).not.toHaveBeenCalled();
  });

  it("surfaces a not-found error when the email has no account", async () => {
    grantGuest.mockRejectedValue(new GuestNotFoundError("ghost@x.test"));
    renderDialog();
    await screen.findByText("Not shared with anyone yet.");

    fireEvent.change(screen.getByLabelText("Email"), {
      target: { value: "ghost@x.test" },
    });
    fireEvent.click(screen.getByRole("button", { name: "Share" }));

    await waitFor(() =>
      expect(toast).toHaveBeenCalledWith(
        expect.objectContaining({ title: "No user with that email" }),
      ),
    );
  });

  it("blocks a duplicate grant (pre-check) and rolls back the optimistic row", async () => {
    // An existing guest for user 'guest9' is already in the mirror.
    await db.deck_guests.put(makeGuest("g-existing", "guest9"));
    grantGuest.mockImplementation(async () => {
      const guest = makeGuest(newClientId(), "guest9"); // same user
      await db.deck_guests.put(guest);
      return guest;
    });
    revokeGuest.mockImplementation(async (id: string) => {
      await db.deck_guests.delete(id);
    });
    renderDialog();
    await screen.findByText("guest9");

    fireEvent.change(screen.getByLabelText("Email"), {
      target: { value: "guest@posedeck.test" },
    });
    fireEvent.click(screen.getByRole("button", { name: "Share" }));

    await waitFor(() =>
      expect(toast).toHaveBeenCalledWith(
        expect.objectContaining({ title: "Already shared" }),
      ),
    );
    // The duplicate optimistic row was rolled back via revokeGuest.
    await waitFor(() => expect(revokeGuest).toHaveBeenCalled());
  });

  it("revokes a guest and the live query drops the row", async () => {
    await db.deck_guests.put(makeGuest("g1", "guest-user-id"));
    revokeGuest.mockImplementation(async (id: string) => {
      await db.deck_guests.delete(id);
    });
    renderDialog();
    await screen.findByText("guest-user-id");

    fireEvent.click(screen.getByRole("button", { name: "Revoke" }));

    await waitFor(() => expect(revokeGuest).toHaveBeenCalledWith("g1"));
    await waitFor(() =>
      expect(screen.queryByText("guest-user-id")).not.toBeInTheDocument(),
    );
    expect(toast).toHaveBeenCalledWith(
      expect.objectContaining({ title: "Access revoked" }),
    );
  });
});
