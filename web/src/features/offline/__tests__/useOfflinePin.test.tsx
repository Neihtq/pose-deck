/**
 * Component-layer tests for `useOfflinePin(deckId)` (M3 STEP 6).
 *
 * The hook orchestrates the per-deck "Download for offline" toggle: it reads the
 * pin state and cached-image count LIVE from Dexie, exposes a `busy` flag and the
 * last `error`, and `togglePin()` pins/unpins by delegating to the `pinDeck`
 * module. These tests mock the `pinDeck` module (the network/byte-fetching layer)
 * but use the REAL Dexie (fake-indexeddb) so the live-query wiring is exercised
 * end to end — a pin written by the mock is observed by the live query.
 */
import { act, renderHook, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { db } from "@/lib/db";

// Mock the byte-fetching layer. The hook's contract is: call pin/unpin and read
// pin state from Dexie. We make the mocks write/clear the `pinned_decks` row so
// the hook's live query reflects the change (exactly as the real module does).
vi.mock("@/features/offline/pinDeck", () => ({
  pinDeck: vi.fn(async (deckId: string) => {
    await db.pinned_decks.put({ deckId, pinnedAt: Date.now() });
    return 0;
  }),
  unpinDeck: vi.fn(async (deckId: string) => {
    await db.pinned_decks.delete(deckId);
  }),
  pinnedBlobCount: vi.fn(async (deckId: string) => {
    const cards = await db.cards.where("deck").equals(deckId).toArray();
    let total = 0;
    for (const card of cards) {
      total += await db.image_blobs.where("card").equals(card.id).count();
    }
    return total;
  }),
}));

import { useOfflinePin } from "@/features/offline/useOfflinePin";
import { pinDeck, unpinDeck } from "@/features/offline/pinDeck";

const DECK = "deck-1";

beforeEach(async () => {
  vi.clearAllMocks();
  await db.pinned_decks.clear();
  await db.cards.clear();
  await db.image_blobs.clear();
});

afterEach(async () => {
  await db.pinned_decks.clear();
  await db.cards.clear();
  await db.image_blobs.clear();
});

describe("useOfflinePin (M3)", () => {
  it("reports unpinned with zero cached count for a fresh deck", async () => {
    const { result } = renderHook(() => useOfflinePin(DECK));
    await waitFor(() => expect(result.current.pinned).toBe(false));
    expect(result.current.cachedCount).toBe(0);
    expect(result.current.busy).toBe(false);
    expect(result.current.error).toBeNull();
  });

  it("pins on toggle and the live pin state flips to true", async () => {
    const { result } = renderHook(() => useOfflinePin(DECK));
    await waitFor(() => expect(result.current.pinned).toBe(false));

    await act(async () => {
      await result.current.togglePin();
    });

    expect(pinDeck).toHaveBeenCalledWith(DECK);
    await waitFor(() => expect(result.current.pinned).toBe(true));
    expect(result.current.busy).toBe(false);
  });

  it("unpins on toggle when already pinned", async () => {
    await db.pinned_decks.put({ deckId: DECK, pinnedAt: Date.now() });
    const { result } = renderHook(() => useOfflinePin(DECK));
    await waitFor(() => expect(result.current.pinned).toBe(true));

    await act(async () => {
      await result.current.togglePin();
    });

    expect(unpinDeck).toHaveBeenCalledWith(DECK);
    expect(pinDeck).not.toHaveBeenCalled();
    await waitFor(() => expect(result.current.pinned).toBe(false));
  });

  it("derives cachedCount live from image_blobs, not an in-memory counter", async () => {
    await db.cards.put({
      id: "card-1",
      deck: DECK,
      title: "x",
      position: 0,
    } as never);
    const { result } = renderHook(() => useOfflinePin(DECK));
    await waitFor(() => expect(result.current.cachedCount).toBe(0));

    await act(async () => {
      await db.image_blobs.put({
        key: "k1",
        card: "card-1",
        recordId: "img-1",
        blob: new Blob(["bytes"]),
        cachedAt: Date.now(),
      });
    });

    await waitFor(() => expect(result.current.cachedCount).toBe(1));
  });

  it("surfaces the error message when pinning throws", async () => {
    vi.mocked(pinDeck).mockRejectedValueOnce(new Error("network down"));
    const { result } = renderHook(() => useOfflinePin(DECK));
    await waitFor(() => expect(result.current.pinned).toBe(false));

    await act(async () => {
      await result.current.togglePin();
    });

    expect(result.current.error).toBe("network down");
    expect(result.current.busy).toBe(false);
    // Pin failed → state stays unpinned.
    expect(result.current.pinned).toBe(false);
  });

  it("ignores toggle for an undefined deckId (no pin/unpin call)", async () => {
    const { result } = renderHook(() => useOfflinePin(undefined));
    await waitFor(() => expect(result.current.pinned).toBe(false));

    await act(async () => {
      await result.current.togglePin();
    });

    expect(pinDeck).not.toHaveBeenCalled();
    expect(unpinDeck).not.toHaveBeenCalled();
  });

  it("guards re-entrancy synchronously: two same-frame taps run a single pin (react-2)", async () => {
    // Two togglePin() calls fired within the SAME render frame — before React
    // re-renders with busy=true. A state-based guard (`if (busy) return`) reads
    // the closed-over busy=false in both closures, so BOTH would proceed. A
    // synchronous ref guard mutates immediately, so the second call short-circuits.
    const { result } = renderHook(() => useOfflinePin(DECK));
    await waitFor(() => expect(result.current.pinned).toBe(false));

    await act(async () => {
      // Same captured callback instance, dispatched back-to-back with no render
      // in between — exactly the same-frame double-tap window.
      const first = result.current.togglePin();
      const second = result.current.togglePin();
      await Promise.all([first, second]);
    });

    // The second call must have been suppressed by the in-flight ref guard.
    expect(pinDeck).toHaveBeenCalledTimes(1);
    await waitFor(() => expect(result.current.pinned).toBe(true));
    expect(result.current.busy).toBe(false);
  });

  it("reads live pin state directly so a double-tap can't pin then unpin a stale snapshot", async () => {
    // Pre-pin out of band; the live query may not have propagated yet when the
    // user taps. The hook re-reads pinned_decks DIRECTLY inside togglePin, so it
    // must take the unpin branch even before the live value updates.
    await db.pinned_decks.put({ deckId: DECK, pinnedAt: Date.now() });
    const { result } = renderHook(() => useOfflinePin(DECK));

    await act(async () => {
      await result.current.togglePin();
    });

    expect(unpinDeck).toHaveBeenCalledWith(DECK);
    expect(pinDeck).not.toHaveBeenCalled();
    // Let the live query settle (unpin removed the row) before unmounting so the
    // trailing re-render is wrapped in act().
    await waitFor(() => expect(result.current.pinned).toBe(false));
  });
});
