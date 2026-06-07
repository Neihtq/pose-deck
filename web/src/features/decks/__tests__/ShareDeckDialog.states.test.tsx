/**
 * Extended component tests for ShareDeckDialog (M5 sharing) — focusing on the
 * states/edge-cases not covered by ShareDeckDialog.test.tsx:
 *  - Share button disabled empty / "Sharing…" in-flight loading state
 *  - email trimming before grant + email cleared on success / kept on dup
 *  - whitespace-only email is a no-op
 *  - generic (non-typed, non-401) share error → "Couldn't share deck" toast
 *  - 401 on share → clearAuthOnUnauthorized swallows it, NO error toast
 *  - revoke "Revoking…" loading state + disabled button
 *  - revoke generic error → "Couldn't revoke access" toast
 *  - 401 on revoke → swallowed, NO error toast
 *  - multiple guests render with independent revoke buttons
 *
 * As in the sibling file, the guest list reads from the real (fake-indexeddb)
 * `db` live query; grantGuest/revokeGuest are mocked and mirror their effect
 * into Dexie. `clearAuthOnUnauthorized` is a mutable mock so a test can flip it
 * to simulate a 401 being handled.
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

const clearAuthOnUnauthorized = vi.fn((..._a: unknown[]) => false);
vi.mock("@/features/auth/AuthContext", () => ({
  clearAuthOnUnauthorized: (...a: unknown[]) => clearAuthOnUnauthorized(...a),
  useAuth: () => ({ user: { id: "owner1", email: "owner@posedeck.test" } }),
}));

const toast = vi.fn();
vi.mock("@/components/ui/use-toast", () => ({
  toast: (...a: unknown[]) => toast(...a),
}));

import { ShareDeckDialog } from "@/features/decks/ShareDeckDialog";

function renderDialog() {
  return render(<ShareDeckDialog deckId="deck1" open onOpenChange={() => {}} />);
}

function makeGuest(id: string, user: string): DeckGuest {
  return { id, deck: "deck1", user, granted_at: "2026-06-07T00:00:00.000Z" };
}

/** A promise we resolve manually to hold an async handler mid-flight. */
function deferred<T>() {
  let resolve!: (v: T) => void;
  let reject!: (e: unknown) => void;
  const promise = new Promise<T>((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}

beforeEach(async () => {
  grantGuest.mockReset();
  revokeGuest.mockReset();
  toast.mockReset();
  clearAuthOnUnauthorized.mockReset();
  clearAuthOnUnauthorized.mockReturnValue(false);
  await db.deck_guests.clear();
});

describe("ShareDeckDialog — share button states", () => {
  it("disables the Share button when the email field is empty", async () => {
    renderDialog();
    await screen.findByText("Not shared with anyone yet.");
    expect(screen.getByRole("button", { name: "Share" })).toBeDisabled();
  });

  it("enables the Share button once an email is typed", async () => {
    renderDialog();
    await screen.findByText("Not shared with anyone yet.");
    fireEvent.change(screen.getByLabelText("Email"), {
      target: { value: "g@x.test" },
    });
    expect(screen.getByRole("button", { name: "Share" })).toBeEnabled();
  });

  it("shows the 'Sharing…' in-flight state and disables the button while granting", async () => {
    const gate = deferred<DeckGuest>();
    grantGuest.mockReturnValue(gate.promise);
    renderDialog();
    await screen.findByText("Not shared with anyone yet.");

    fireEvent.change(screen.getByLabelText("Email"), {
      target: { value: "g@x.test" },
    });
    fireEvent.click(screen.getByRole("button", { name: "Share" }));

    // Loading label appears and the button is disabled mid-flight.
    const sharingBtn = await screen.findByRole("button", { name: "Sharing…" });
    expect(sharingBtn).toBeDisabled();

    // Resolve to a fresh row so the handler completes cleanly.
    const guest = makeGuest(newClientId(), "guest9");
    await db.deck_guests.put(guest);
    gate.resolve(guest);

    await screen.findByRole("button", { name: "Share" });
  });
});

describe("ShareDeckDialog — email handling", () => {
  it("trims surrounding whitespace before calling grantGuest", async () => {
    grantGuest.mockImplementation(async () => {
      const guest = makeGuest(newClientId(), "guest9");
      await db.deck_guests.put(guest);
      return guest;
    });
    renderDialog();
    await screen.findByText("Not shared with anyone yet.");

    fireEvent.change(screen.getByLabelText("Email"), {
      target: { value: "  guest@posedeck.test  " },
    });
    fireEvent.click(screen.getByRole("button", { name: "Share" }));

    await waitFor(() =>
      expect(grantGuest).toHaveBeenCalledWith("deck1", "guest@posedeck.test"),
    );
  });

  it("clears the email field after a successful share", async () => {
    grantGuest.mockImplementation(async () => {
      const guest = makeGuest(newClientId(), "guest9");
      await db.deck_guests.put(guest);
      return guest;
    });
    renderDialog();
    await screen.findByText("Not shared with anyone yet.");

    const input = screen.getByLabelText("Email") as HTMLInputElement;
    fireEvent.change(input, { target: { value: "guest@posedeck.test" } });
    fireEvent.click(screen.getByRole("button", { name: "Share" }));

    await waitFor(() => expect(input.value).toBe(""));
  });

  it("keeps the email field populated when the grant was a blocked duplicate", async () => {
    await db.deck_guests.put(makeGuest("g-existing", "guest9"));
    grantGuest.mockImplementation(async () => {
      const guest = makeGuest(newClientId(), "guest9"); // same user → dup
      await db.deck_guests.put(guest);
      return guest;
    });
    revokeGuest.mockImplementation(async (id: string) => {
      await db.deck_guests.delete(id);
    });
    renderDialog();
    await screen.findByText("guest9");

    const input = screen.getByLabelText("Email") as HTMLInputElement;
    fireEvent.change(input, { target: { value: "guest@posedeck.test" } });
    fireEvent.click(screen.getByRole("button", { name: "Share" }));

    await waitFor(() =>
      expect(toast).toHaveBeenCalledWith(
        expect.objectContaining({ title: "Already shared" }),
      ),
    );
    // Not cleared — the user can correct the address.
    expect(input.value).toBe("guest@posedeck.test");
  });

  it("does nothing for a whitespace-only email (no grant, no toast)", async () => {
    renderDialog();
    await screen.findByText("Not shared with anyone yet.");

    const input = screen.getByLabelText("Email");
    // The button stays disabled for whitespace; submit the form directly to
    // prove the handler short-circuits even if a submit is forced.
    fireEvent.change(input, { target: { value: "   " } });
    fireEvent.submit(input.closest("form")!);

    await Promise.resolve();
    expect(grantGuest).not.toHaveBeenCalled();
    expect(toast).not.toHaveBeenCalled();
  });
});

describe("ShareDeckDialog — share error handling", () => {
  it("shows a generic error toast for an unexpected share failure", async () => {
    grantGuest.mockRejectedValue(new Error("boom"));
    renderDialog();
    await screen.findByText("Not shared with anyone yet.");

    fireEvent.change(screen.getByLabelText("Email"), {
      target: { value: "g@x.test" },
    });
    fireEvent.click(screen.getByRole("button", { name: "Share" }));

    await waitFor(() =>
      expect(toast).toHaveBeenCalledWith(
        expect.objectContaining({ title: "Couldn't share deck" }),
      ),
    );
    // Returns to a usable state.
    await screen.findByRole("button", { name: "Share" });
  });

  it("swallows a 401 on share (no error toast) when auth is cleared", async () => {
    grantGuest.mockRejectedValue({ status: 401 });
    clearAuthOnUnauthorized.mockReturnValue(true); // handled as a 401
    renderDialog();
    await screen.findByText("Not shared with anyone yet.");

    fireEvent.change(screen.getByLabelText("Email"), {
      target: { value: "g@x.test" },
    });
    fireEvent.click(screen.getByRole("button", { name: "Share" }));

    await waitFor(() => expect(clearAuthOnUnauthorized).toHaveBeenCalled());
    // No "Couldn't share deck" toast because the 401 path consumed the error.
    expect(toast).not.toHaveBeenCalledWith(
      expect.objectContaining({ title: "Couldn't share deck" }),
    );
  });
});

describe("ShareDeckDialog — revoke states and errors", () => {
  it("shows the 'Revoking…' state and disables the button while revoking", async () => {
    await db.deck_guests.put(makeGuest("g1", "guest-user-id"));
    const gate = deferred<void>();
    revokeGuest.mockReturnValue(gate.promise);
    renderDialog();
    await screen.findByText("guest-user-id");

    fireEvent.click(screen.getByRole("button", { name: "Revoke" }));

    const revokingBtn = await screen.findByRole("button", {
      name: "Revoking…",
    });
    expect(revokingBtn).toBeDisabled();

    await db.deck_guests.delete("g1");
    gate.resolve();
    await waitFor(() =>
      expect(screen.queryByText("guest-user-id")).not.toBeInTheDocument(),
    );
  });

  it("shows a generic error toast and keeps the row when revoke fails", async () => {
    await db.deck_guests.put(makeGuest("g1", "guest-user-id"));
    revokeGuest.mockRejectedValue(new Error("network down"));
    renderDialog();
    await screen.findByText("guest-user-id");

    fireEvent.click(screen.getByRole("button", { name: "Revoke" }));

    await waitFor(() =>
      expect(toast).toHaveBeenCalledWith(
        expect.objectContaining({ title: "Couldn't revoke access" }),
      ),
    );
    // Row stays because the delete did not happen.
    expect(screen.getByText("guest-user-id")).toBeInTheDocument();
    // Button is re-enabled for a retry.
    expect(screen.getByRole("button", { name: "Revoke" })).toBeEnabled();
  });

  it("swallows a 401 on revoke (no error toast) when auth is cleared", async () => {
    await db.deck_guests.put(makeGuest("g1", "guest-user-id"));
    revokeGuest.mockRejectedValue({ status: 401 });
    clearAuthOnUnauthorized.mockReturnValue(true);
    renderDialog();
    await screen.findByText("guest-user-id");

    fireEvent.click(screen.getByRole("button", { name: "Revoke" }));

    await waitFor(() => expect(clearAuthOnUnauthorized).toHaveBeenCalled());
    expect(toast).not.toHaveBeenCalledWith(
      expect.objectContaining({ title: "Couldn't revoke access" }),
    );
  });
});

describe("ShareDeckDialog — a11y (M8)", () => {
  it("exposes a dialog role labelled by its title", async () => {
    renderDialog();
    const dialog = await screen.findByRole("dialog");
    // Radix wires aria-labelledby → the DialogTitle, so the dialog has an
    // accessible name.
    expect(dialog).toHaveAccessibleName("Share deck");
  });

  it("labels the email input", async () => {
    renderDialog();
    await screen.findByText("Not shared with anyone yet.");
    expect(screen.getByLabelText("Email")).toBeInTheDocument();
  });
});

describe("ShareDeckDialog — multiple guests", () => {
  it("renders a revoke button per guest and revokes the chosen one", async () => {
    await db.deck_guests.put(makeGuest("g1", "alice-id"));
    await db.deck_guests.put(makeGuest("g2", "bob-id"));
    revokeGuest.mockImplementation(async (id: string) => {
      await db.deck_guests.delete(id);
    });
    renderDialog();
    await screen.findByText("alice-id");
    await screen.findByText("bob-id");

    const revokeButtons = screen.getAllByRole("button", { name: "Revoke" });
    expect(revokeButtons).toHaveLength(2);

    // Revoke alice (the first row).
    fireEvent.click(revokeButtons[0]);

    await waitFor(() => expect(revokeGuest).toHaveBeenCalledWith("g1"));
    await waitFor(() =>
      expect(screen.queryByText("alice-id")).not.toBeInTheDocument(),
    );
    // bob remains.
    expect(screen.getByText("bob-id")).toBeInTheDocument();
  });
});
