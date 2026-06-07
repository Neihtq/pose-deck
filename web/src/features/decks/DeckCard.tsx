/**
 * A single deck tile for the deck-list grid (DESIGN.md §3.3).
 *
 * Shows the deck name + (optional) shoot date and exposes per-deck operations
 * via a dropdown menu: open, rename, duplicate, delete (soft-delete confirmed
 * through an alert dialog). The card body navigates to the deck detail route.
 *
 * This is a presentational subcomponent — all mutations are handled by the
 * parent (DeckListPage) through the callback props so list state stays in one
 * place. Co-located with DeckListPage by design.
 */
import * as React from "react";

import { MoreVertical } from "lucide-react";

import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from "@/components/ui/alert-dialog";
import { buttonVariants } from "@/components/ui/button";
import { Card, CardHeader, CardTitle } from "@/components/ui/card";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { imageDisplayUrl } from "@/features/images/imageApi";
import { OfflineImage } from "@/features/offline/OfflineImage";
import { cn } from "@/lib/utils";
import type { CardImage, Deck } from "@/lib/types";

/** Format an ISO shoot date for display, or null when unset/unparseable. */
function formatShootDate(shootDate: string): string | null {
  if (typeof shootDate !== "string" || shootDate === "") {
    return null;
  }
  const ms = Date.parse(shootDate);
  if (Number.isNaN(ms)) {
    return null;
  }
  return new Date(ms).toLocaleDateString(undefined, {
    weekday: "short",
    year: "numeric",
    month: "short",
    day: "numeric",
  });
}

export interface DeckCardProps {
  deck: Deck;
  /**
   * Auto-thumbnail (DESIGN.md §3.3): the first image of the deck's first card,
   * resolved to a `CardImage` record by the parent. The tile renders it through
   * `<OfflineImage>`, which consults the offline `image_blobs` pin first and
   * only falls back to a network token URL — so a pinned deck's tile works
   * offline (DESIGN.md §2.2 / §5), mirroring deck detail / the card editor.
   * `null`/omitted renders a placeholder (deck has no cards/images, or the
   * lookup is still resolving).
   */
  thumbnailImage?: CardImage | null;
  /**
   * True while a mutation (duplicate/delete) for this deck is in flight in the
   * parent. The destructive actions are disabled so the user cannot re-fire a
   * non-idempotent mutation (e.g. Duplicate) on the same deck before the list
   * refreshes. Mirrors TrashView's `restoringId` per-row busy guard.
   */
  pending?: boolean;
  onOpen: (deck: Deck) => void;
  onRename: (deck: Deck) => void;
  onDuplicate: (deck: Deck) => void;
  onDelete: (deck: Deck) => void;
}

export function DeckCard({
  deck,
  thumbnailImage = null,
  pending = false,
  onOpen,
  onRename,
  onDuplicate,
  onDelete,
}: DeckCardProps): React.JSX.Element {
  const [confirmOpen, setConfirmOpen] = React.useState(false);
  const shootDateLabel = formatShootDate(deck.shoot_date);

  // Close the confirm dialog once the parent's delete mutation settles (the
  // `pending` flag drops back to false). Because the Delete action calls
  // `e.preventDefault()`, the dialog stays open during the in-flight mutation
  // instead of auto-closing and re-exposing the card to a duplicate request.
  const wasPending = React.useRef(false);
  React.useEffect(() => {
    if (wasPending.current && !pending) {
      setConfirmOpen(false);
    }
    wasPending.current = pending;
  }, [pending]);

  return (
    <Card className="relative transition-colors hover:border-foreground/20">
      <button
        type="button"
        onClick={() => onOpen(deck)}
        className="block w-full rounded-xl text-left focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
      >
        {thumbnailImage ? (
          <OfflineImage
            image={thumbnailImage}
            thumb="400x300"
            networkUrl={imageDisplayUrl}
            alt=""
            className="aspect-video w-full rounded-t-xl object-cover"
            loading="lazy"
            fallback={
              <div className="aspect-video w-full animate-pulse rounded-t-xl bg-muted" />
            }
          />
        ) : (
          <div className="flex aspect-video w-full items-center justify-center rounded-t-xl bg-muted text-xs text-muted-foreground">
            No image
          </div>
        )}
        <CardHeader className="pr-12">
          <CardTitle className="truncate">{deck.name}</CardTitle>
          <p className="text-sm text-muted-foreground">
            {shootDateLabel ?? "No shoot date"}
          </p>
        </CardHeader>
      </button>

      <div className="absolute right-3 top-3">
        <DropdownMenu>
          <DropdownMenuTrigger
            className={cn(
              buttonVariants({ variant: "ghost", size: "icon" }),
              "h-8 w-8",
            )}
            aria-label={`Deck actions for ${deck.name}`}
          >
            <MoreVertical className="h-4 w-4" />
          </DropdownMenuTrigger>
          <DropdownMenuContent align="end">
            <DropdownMenuItem onSelect={() => onOpen(deck)}>
              Open
            </DropdownMenuItem>
            <DropdownMenuItem onSelect={() => onRename(deck)}>
              Rename
            </DropdownMenuItem>
            <DropdownMenuItem
              onSelect={() => onDuplicate(deck)}
              disabled={pending}
            >
              Duplicate
            </DropdownMenuItem>
            <DropdownMenuSeparator />
            <DropdownMenuItem
              className="text-destructive focus:text-destructive"
              onSelect={() => setConfirmOpen(true)}
              disabled={pending}
            >
              Delete
            </DropdownMenuItem>
          </DropdownMenuContent>
        </DropdownMenu>
      </div>

      <AlertDialog open={confirmOpen} onOpenChange={setConfirmOpen}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>Delete “{deck.name}”?</AlertDialogTitle>
            <AlertDialogDescription>
              This moves the deck to Trash. You can restore it for 30 days
              before it is permanently removed.
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel disabled={pending}>Cancel</AlertDialogCancel>
            <AlertDialogAction
              className={buttonVariants({ variant: "destructive" })}
              disabled={pending}
              onClick={(e) => {
                // Keep the dialog open while the parent's soft-delete + refresh
                // are in flight (errors surface via toast on the list); closing
                // immediately would re-expose the still-rendered card to a
                // second Delete/Duplicate before the refresh lands.
                e.preventDefault();
                onDelete(deck);
              }}
            >
              Delete
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </Card>
  );
}
