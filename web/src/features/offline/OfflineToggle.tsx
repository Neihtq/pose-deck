/**
 * `<OfflineToggle>` — the per-deck "Download for offline" control (M3 STEP 6).
 *
 * Pins / unpins the deck's images for offline use via {@link useOfflinePin}. The
 * service worker only precaches the static app shell, so this explicit pin is
 * what lets a deck's images render with no network. Shown in the deck-detail
 * header. While offline the button is disabled for a NOT-yet-pinned deck (we
 * can't fetch new bytes), but unpinning an already-pinned deck stays available.
 */
import * as React from "react";
import { Download, DownloadCloud, Loader2 } from "lucide-react";

import { Button } from "@/components/ui/button";
import { toast } from "@/components/ui/use-toast";
import { useOfflinePin } from "@/features/offline/useOfflinePin";
import { useOnlineStatus } from "@/features/offline/useOnlineStatus";

export interface OfflineToggleProps {
  deckId: string;
}

export function OfflineToggle({ deckId }: OfflineToggleProps): React.JSX.Element {
  const { pinned, cachedCount, busy, error, togglePin } = useOfflinePin(deckId);
  const online = useOnlineStatus();

  // Surface a pin failure once per occurrence.
  const lastError = React.useRef<string | null>(null);
  React.useEffect(() => {
    if (error && error !== lastError.current) {
      toast({
        variant: "destructive",
        title: "Offline copy failed",
        description: error,
      });
    }
    lastError.current = error;
  }, [error]);

  const isPinned = pinned === true;
  // Can't fetch new bytes while offline; allow unpinning a pinned deck though.
  const disabled = busy || (!online && !isPinned);

  const label = isPinned
    ? cachedCount > 0
      ? `Offline (${cachedCount})`
      : "Offline"
    : "Download for offline";

  return (
    <Button
      type="button"
      variant={isPinned ? "secondary" : "outline"}
      size="sm"
      disabled={disabled}
      aria-pressed={isPinned}
      onClick={() => void togglePin()}
      title={
        !online && !isPinned
          ? "Connect to the internet to download this deck for offline use"
          : undefined
      }
    >
      {busy ? (
        <Loader2 className="h-4 w-4 animate-spin" />
      ) : isPinned ? (
        <DownloadCloud className="h-4 w-4" />
      ) : (
        <Download className="h-4 w-4" />
      )}
      {label}
    </Button>
  );
}
