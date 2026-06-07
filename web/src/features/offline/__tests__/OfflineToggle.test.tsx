/**
 * Component-layer tests for `<OfflineToggle>` (M3 STEP 6).
 *
 * The toggle renders the per-deck "Download for offline" button. It composes
 * two hooks (`useOfflinePin`, `useOnlineStatus`) which we mock here so each test
 * pins the exact state under test (pinned/unpinned, busy, online/offline, error)
 * and asserts the button's label, `aria-pressed`, disabled state, the click →
 * `togglePin` wiring, and the one-shot error toast.
 */
import { fireEvent, render, screen } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import type { OfflinePinState } from "@/features/offline/useOfflinePin";

const togglePin = vi.fn();
const toast = vi.fn();

let pinState: OfflinePinState;
let online: boolean;

vi.mock("@/components/ui/use-toast", () => ({
  toast: (...args: unknown[]) => toast(...args),
}));
vi.mock("@/features/offline/useOfflinePin", () => ({
  useOfflinePin: () => pinState,
}));
vi.mock("@/features/offline/useOnlineStatus", () => ({
  useOnlineStatus: () => online,
}));

import { OfflineToggle } from "@/features/offline/OfflineToggle";

function setState(overrides: Partial<OfflinePinState> = {}): void {
  pinState = {
    pinned: false,
    cachedCount: 0,
    busy: false,
    error: null,
    togglePin,
    ...overrides,
  };
}

beforeEach(() => {
  togglePin.mockReset();
  toast.mockReset();
  online = true;
  setState();
});

describe("<OfflineToggle> (M3)", () => {
  it("renders 'Download for offline' when unpinned and online", () => {
    setState({ pinned: false });
    render(<OfflineToggle deckId="d1" />);
    const btn = screen.getByRole("button");
    expect(btn).toHaveTextContent("Download for offline");
    expect(btn).toHaveAttribute("aria-pressed", "false");
    expect(btn).not.toBeDisabled();
  });

  it("renders 'Offline (N)' with the cached count when pinned", () => {
    setState({ pinned: true, cachedCount: 7 });
    render(<OfflineToggle deckId="d1" />);
    const btn = screen.getByRole("button");
    expect(btn).toHaveTextContent("Offline (7)");
    expect(btn).toHaveAttribute("aria-pressed", "true");
  });

  it("renders 'Offline' without a count when pinned but zero bytes cached", () => {
    setState({ pinned: true, cachedCount: 0 });
    render(<OfflineToggle deckId="d1" />);
    expect(screen.getByRole("button")).toHaveTextContent(/^Offline$/);
  });

  it("calls togglePin when clicked", () => {
    setState({ pinned: false });
    render(<OfflineToggle deckId="d1" />);
    fireEvent.click(screen.getByRole("button"));
    expect(togglePin).toHaveBeenCalledTimes(1);
  });

  it("disables the button while busy", () => {
    setState({ busy: true });
    render(<OfflineToggle deckId="d1" />);
    expect(screen.getByRole("button")).toBeDisabled();
  });

  it("disables and explains when offline and the deck is NOT pinned", () => {
    online = false;
    setState({ pinned: false });
    render(<OfflineToggle deckId="d1" />);
    const btn = screen.getByRole("button");
    expect(btn).toBeDisabled();
    expect(btn).toHaveAttribute(
      "title",
      "Connect to the internet to download this deck for offline use",
    );
  });

  it("stays enabled when offline but the deck IS pinned (unpin allowed)", () => {
    online = false;
    setState({ pinned: true });
    render(<OfflineToggle deckId="d1" />);
    const btn = screen.getByRole("button");
    expect(btn).not.toBeDisabled();
    expect(btn).not.toHaveAttribute("title");
  });

  it("fires a destructive toast once when an error appears", () => {
    setState({ error: "Offline copy failed: 500" });
    const { rerender } = render(<OfflineToggle deckId="d1" />);
    expect(toast).toHaveBeenCalledTimes(1);
    expect(toast).toHaveBeenCalledWith(
      expect.objectContaining({
        variant: "destructive",
        title: "Offline copy failed",
        description: "Offline copy failed: 500",
      }),
    );

    // A re-render with the SAME error must NOT re-fire the toast (one per
    // occurrence — the component dedupes on the error string).
    rerender(<OfflineToggle deckId="d1" />);
    expect(toast).toHaveBeenCalledTimes(1);
  });

  it("does not toast when there is no error", () => {
    setState({ error: null });
    render(<OfflineToggle deckId="d1" />);
    expect(toast).not.toHaveBeenCalled();
  });
});
