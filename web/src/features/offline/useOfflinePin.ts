/**
 * `useOfflinePin(deckId)` — drives the per-deck "Download for offline" toggle
 * (M3 STEP 6).
 *
 * Exposes the deck's pin state (read LIVE from `pinned_decks` so it reflects a
 * cross-tab pin), the cached-image count (derived live from `image_blobs` via
 * `pinnedBlobCount`, never an in-memory counter), an in-flight `busy` flag, and
 * `togglePin()` to pin / unpin. The actual byte fetching lives in
 * `features/offline/pinDeck`; this hook only orchestrates the call and surfaces
 * state to the toggle component.
 */
import * as React from "react";

import { db } from "@/lib/db";
import { useLiveQuery } from "@/lib/useLiveQuery";
import {
  pinDeck,
  pinnedBlobCount,
  unpinDeck,
} from "@/features/offline/pinDeck";

export interface OfflinePinState {
  /** Whether the deck is pinned. `undefined` while the live query loads. */
  pinned: boolean | undefined;
  /** Number of cached image-byte rows for the deck (live, derived). */
  cachedCount: number;
  /** True while a pin/unpin is in flight. */
  busy: boolean;
  /** The last pin error, if any (cleared on the next attempt). */
  error: string | null;
  /** Pin if unpinned, unpin if pinned. No-op while already busy. */
  togglePin: () => Promise<void>;
}

export function useOfflinePin(deckId: string | undefined): OfflinePinState {
  // Live pin state: re-renders if the pin is added/removed in any tab.
  const pinned = useLiveQuery<boolean>(
    () =>
      deckId
        ? db.pinned_decks.get(deckId).then((p) => p !== undefined)
        : Promise.resolve(false),
    [deckId],
  );

  // Live cached-image count, derived from the blobs table (not a counter).
  const cachedCount = useLiveQuery<number>(
    () => (deckId ? pinnedBlobCount(deckId) : Promise.resolve(0)),
    [deckId],
  );

  const [busy, setBusy] = React.useState(false);
  const [error, setError] = React.useState<string | null>(null);

  const togglePin = React.useCallback(async () => {
    if (!deckId || busy) {
      return;
    }
    setBusy(true);
    setError(null);
    try {
      // Read the current state directly (not the possibly-stale live value) so
      // a rapid double-tap can't pin and unpin against an out-of-date snapshot.
      const alreadyPinned =
        (await db.pinned_decks.get(deckId)) !== undefined;
      if (alreadyPinned) {
        await unpinDeck(deckId);
      } else {
        await pinDeck(deckId);
      }
    } catch (err) {
      setError(err instanceof Error ? err.message : "Could not update offline copy.");
    } finally {
      setBusy(false);
    }
  }, [deckId, busy]);

  return {
    pinned,
    cachedCount: cachedCount ?? 0,
    busy,
    error,
    togglePin,
  };
}
