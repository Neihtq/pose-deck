/**
 * Deck detail page (route `/decks/:id`).
 *
 * Shows a single deck's cards as an ordered, drag-droppable list. Cards are
 * loaded via `cardApi.listCards`; reordering is optimistic (the list updates
 * immediately) and persisted with `cardApi.reorderCards`. Reorders are
 * serialized — a new drag is blocked while one is in flight — and on failure
 * the authoritative order is re-fetched via `cardApi.listCards` rather than
 * reverting to a possibly-stale local snapshot.
 *
 * The header shows the deck name with inline rename, a back link to the deck
 * list ("/"), and a duplicate / delete menu. Each card row shows its
 * title / time slot / subjects / direction plus a thumbnail (the first card
 * image, via `images.imageDisplayUrl`). "Add card" creates a card and opens
 * the card editor; clicking a row opens the editor for that card.
 *
 * M1 talks to PocketBase directly (via the deck/card APIs); outbox sync is M3.
 */
import * as React from "react";
import { Link, useNavigate, useParams } from "react-router-dom";

import {
  DndContext,
  KeyboardSensor,
  PointerSensor,
  closestCenter,
  useSensor,
  useSensors,
  type DragEndEvent,
  type Modifier,
} from "@dnd-kit/core";
import {
  SortableContext,
  arrayMove,
  sortableKeyboardCoordinates,
  useSortable,
  verticalListSortingStrategy,
} from "@dnd-kit/sortable";
import { CSS } from "@dnd-kit/utilities";

import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
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
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { toast } from "@/components/ui/use-toast";
import { cn } from "@/lib/utils";
import type { Card as CardRecord, CardImage } from "@/lib/types";

import { clearAuthOnUnauthorized } from "@/features/auth/AuthContext";
import {
  createCard,
  listCards,
  reorderCards,
} from "@/features/cards/cardApi";
import { duplicateDeck, getDeck, renameDeck, softDeleteDeck } from "@/features/decks/deckApi";
import { imageDisplayUrl, listCardImages } from "@/features/images/imageApi";
import type { Deck } from "@/lib/types";

/**
 * dnd-kit modifier that locks dragging to the vertical axis. We implement it
 * inline (rather than `@dnd-kit/modifiers`, which is not a dependency) so the
 * sortable list only translates up/down.
 */
const restrictToVerticalAxis: Modifier = ({ transform }) => ({
  ...transform,
  x: 0,
});

/**
 * Per-card thumbnail state keyed by card id: the resolved (token-carrying)
 * display URL plus the source {@link CardImage} so an expired-token `<img>`
 * `onError` can re-mint a fresh URL (see {@link handleThumbnailError}).
 */
interface Thumbnail {
  url: string;
  image: CardImage;
}
type ThumbnailMap = Record<string, Thumbnail | null>;

export default function DeckDetailPage(): React.JSX.Element {
  const { id } = useParams<{ id: string }>();
  const navigate = useNavigate();

  const [deck, setDeck] = React.useState<Deck | null>(null);
  const [cards, setCards] = React.useState<CardRecord[]>([]);
  const [thumbnails, setThumbnails] = React.useState<ThumbnailMap>({});
  const [loading, setLoading] = React.useState(true);
  const [error, setError] = React.useState<string | null>(null);

  // True while a `reorderCards` request is in flight. We block starting a new
  // reorder until the previous one settles: overlapping optimistic reorders
  // would capture each other's intermediate (non-server-confirmed) state as
  // their revert baseline, so a later failure could restore a stale order.
  const [reordering, setReordering] = React.useState(false);

  const [renameOpen, setRenameOpen] = React.useState(false);
  const [renameValue, setRenameValue] = React.useState("");
  const [renaming, setRenaming] = React.useState(false);

  const [deleteOpen, setDeleteOpen] = React.useState(false);
  const [busy, setBusy] = React.useState(false);
  const [creating, setCreating] = React.useState(false);

  const sensors = useSensors(
    useSensor(PointerSensor, { activationConstraint: { distance: 4 } }),
    useSensor(KeyboardSensor, {
      coordinateGetter: sortableKeyboardCoordinates,
    }),
  );

  // Load the deck + its cards (and per-card first-image thumbnails).
  React.useEffect(() => {
    if (!id) {
      return;
    }
    let cancelled = false;
    setLoading(true);
    setError(null);

    (async () => {
      try {
        const [loadedDeck, loadedCards] = await Promise.all([
          getDeck(id),
          listCards(id),
        ]);
        if (cancelled) {
          return;
        }
        setDeck(loadedDeck);
        setCards(loadedCards);

        // Best-effort: fetch the first image for each card for thumbnails.
        const thumbEntries = await Promise.all(
          loadedCards.map(
            async (card): Promise<[string, Thumbnail | null]> => {
              try {
                const imgs: CardImage[] = await listCardImages(card.id);
                const first = imgs[0];
                if (!first) {
                  return [card.id, null];
                }
                const url = await imageDisplayUrl(first, { thumb: "200x200" });
                return [card.id, { url, image: first }];
              } catch {
                return [card.id, null];
              }
            },
          ),
        );
        if (!cancelled) {
          setThumbnails(Object.fromEntries(thumbEntries));
        }
      } catch (err) {
        if (cancelled) {
          return;
        }
        clearAuthOnUnauthorized(err);
        setError("Couldn't load this deck.");
      } finally {
        if (!cancelled) {
          setLoading(false);
        }
      }
    })();

    return () => {
      cancelled = true;
    };
  }, [id]);

  // Re-mint a thumbnail's display URL when its <img> fails to load. The load
  // effect resolves each URL once (deps `[id]`) with a short-lived `?token=`
  // (FILE_TOKEN_TTL_MS in pocketbase.ts), so on a long-lived deck-detail view a
  // browser re-fetch after the token expires (lazy reveal, cache eviction,
  // reconnect) 4xxs and the thumbnail breaks. Re-resolving gets a fresh token.
  // Mirrors CardEditor's handleImageError (react-1): we only update state when
  // the refreshed URL actually differs, so a genuine 404 (unchanged URL) does
  // not spin in an error → re-render → error loop.
  const handleThumbnailError = React.useCallback(
    async (cardId: string, image: CardImage) => {
      try {
        const fresh = await imageDisplayUrl(image, { thumb: "200x200" });
        setThumbnails((prev) => {
          const current = prev[cardId];
          if (!current || current.url === fresh) {
            return prev;
          }
          return { ...prev, [cardId]: { url: fresh, image } };
        });
      } catch {
        // Leave the broken thumbnail as-is; nothing more we can do here.
      }
    },
    [],
  );

  const handleDragEnd = React.useCallback(
    (event: DragEndEvent) => {
      // Serialize persistence: ignore drops while a reorder is still in flight
      // so we never optimistically stack a second reorder on top of an
      // unconfirmed one (which would corrupt the revert baseline).
      if (reordering || !id) {
        return;
      }
      const { active, over } = event;
      if (!over || active.id === over.id) {
        return;
      }
      const oldIndex = cards.findIndex((c) => c.id === active.id);
      const newIndex = cards.findIndex((c) => c.id === over.id);
      if (oldIndex === -1 || newIndex === -1) {
        return;
      }

      const reordered = arrayMove(cards, oldIndex, newIndex);
      setCards(reordered); // optimistic
      setReordering(true);

      const orderedIds = reordered.map((c) => c.id);
      // Pass the pre-reorder positions so reorderCards can skip cards that did
      // not actually move, avoiding needless client_updated_at bumps that could
      // clobber concurrent edits under last-write-wins (ARCHITECTURE.md §4.3).
      const currentPositions = new Map(cards.map((c) => [c.id, c.position]));
      reorderCards(id, orderedIds, currentPositions)
        .catch(async (err) => {
          clearAuthOnUnauthorized(err);
          // Don't trust a local snapshot: a non-atomic reorder may have
          // partially restriped the server, so re-fetch the authoritative
          // order rather than reverting to a possibly-stale local order.
          try {
            const fresh = await listCards(id);
            setCards(fresh);
          } catch (refetchErr) {
            clearAuthOnUnauthorized(refetchErr);
          }
          toast({
            variant: "destructive",
            title: "Reorder failed",
            description: "Couldn't save the new order. Please try again.",
          });
        })
        .finally(() => {
          setReordering(false);
        });
    },
    [cards, id, reordering],
  );

  const openRename = React.useCallback(() => {
    setRenameValue(deck?.name ?? "");
    setRenameOpen(true);
  }, [deck?.name]);

  const handleRename = React.useCallback(
    async (event: React.FormEvent) => {
      event.preventDefault();
      const next = renameValue.trim();
      if (!deck || next === "" || next === deck.name) {
        setRenameOpen(false);
        return;
      }
      setRenaming(true);
      try {
        const updated = await renameDeck(deck.id, next);
        setDeck(updated);
        setRenameOpen(false);
      } catch (err) {
        clearAuthOnUnauthorized(err);
        toast({
          variant: "destructive",
          title: "Rename failed",
          description: "Couldn't rename this deck. Please try again.",
        });
      } finally {
        setRenaming(false);
      }
    },
    [deck, renameValue],
  );

  const handleDuplicate = React.useCallback(async () => {
    if (!deck) {
      return;
    }
    setBusy(true);
    try {
      const copy = await duplicateDeck(deck.id);
      toast({ title: "Deck duplicated", description: copy.name });
      navigate(`/decks/${copy.id}`);
    } catch (err) {
      clearAuthOnUnauthorized(err);
      toast({
        variant: "destructive",
        title: "Duplicate failed",
        description: "Couldn't duplicate this deck. Please try again.",
      });
    } finally {
      setBusy(false);
    }
  }, [deck, navigate]);

  const handleDelete = React.useCallback(async () => {
    if (!deck) {
      return;
    }
    setBusy(true);
    try {
      await softDeleteDeck(deck.id);
      setDeleteOpen(false);
      toast({ title: "Deck moved to trash" });
      navigate("/");
    } catch (err) {
      clearAuthOnUnauthorized(err);
      toast({
        variant: "destructive",
        title: "Delete failed",
        description: "Couldn't delete this deck. Please try again.",
      });
    } finally {
      setBusy(false);
    }
  }, [deck, navigate]);

  const handleAddCard = React.useCallback(async () => {
    if (!id) {
      return;
    }
    setCreating(true);
    try {
      const card = await createCard(id, { title: "Untitled card" });
      setCards((prev) => [...prev, card]);
      navigate(`/decks/${id}/cards/${card.id}`);
    } catch (err) {
      clearAuthOnUnauthorized(err);
      toast({
        variant: "destructive",
        title: "Couldn't add card",
        description: "Please try again.",
      });
    } finally {
      setCreating(false);
    }
  }, [id, navigate]);

  const openCard = React.useCallback(
    (cardId: string) => {
      if (!id) {
        return;
      }
      navigate(`/decks/${id}/cards/${cardId}`);
    },
    [id, navigate],
  );

  if (loading) {
    return (
      <div className="mx-auto w-full max-w-3xl px-4 py-10">
        <p className="text-sm text-muted-foreground">Loading deck…</p>
      </div>
    );
  }

  if (error || !deck) {
    return (
      <div className="mx-auto w-full max-w-3xl px-4 py-10">
        <Link to="/" className="text-sm text-muted-foreground hover:underline">
          ← Back to decks
        </Link>
        <p className="mt-6 text-sm text-destructive">
          {error ?? "Deck not found."}
        </p>
      </div>
    );
  }

  return (
    <div className="mx-auto w-full max-w-3xl px-4 py-8">
      <div className="mb-6">
        <Link
          to="/"
          className="text-sm text-muted-foreground hover:underline"
        >
          ← Back to decks
        </Link>
      </div>

      <header className="mb-6 flex items-start justify-between gap-4">
        <div className="min-w-0">
          <h1 className="truncate text-2xl font-semibold tracking-tight">
            {deck.name}
          </h1>
          <p className="mt-1 text-sm text-muted-foreground">
            {cards.length} {cards.length === 1 ? "card" : "cards"}
          </p>
        </div>
        <div className="flex shrink-0 items-center gap-2">
          <Button onClick={handleAddCard} disabled={creating}>
            {creating ? "Adding…" : "Add card"}
          </Button>
          <DropdownMenu>
            <DropdownMenuTrigger asChild>
              <Button variant="outline" size="icon" aria-label="Deck options">
                <span aria-hidden>⋯</span>
              </Button>
            </DropdownMenuTrigger>
            <DropdownMenuContent align="end">
              <DropdownMenuItem onSelect={openRename}>Rename</DropdownMenuItem>
              <DropdownMenuItem onSelect={handleDuplicate} disabled={busy}>
                Duplicate
              </DropdownMenuItem>
              <DropdownMenuSeparator />
              <DropdownMenuItem
                className="text-destructive focus:text-destructive"
                onSelect={() => setDeleteOpen(true)}
              >
                Delete
              </DropdownMenuItem>
            </DropdownMenuContent>
          </DropdownMenu>
        </div>
      </header>

      {cards.length === 0 ? (
        <div className="rounded-lg border border-dashed py-16 text-center">
          <p className="text-sm text-muted-foreground">No cards yet.</p>
          <Button className="mt-4" onClick={handleAddCard} disabled={creating}>
            Add your first card
          </Button>
        </div>
      ) : (
        <DndContext
          sensors={sensors}
          collisionDetection={closestCenter}
          modifiers={[restrictToVerticalAxis]}
          onDragEnd={handleDragEnd}
        >
          <SortableContext
            items={cards.map((c) => c.id)}
            strategy={verticalListSortingStrategy}
          >
            <ul className="flex flex-col gap-2">
              {cards.map((card) => (
                <SortableCardRow
                  key={card.id}
                  card={card}
                  thumbnail={thumbnails[card.id] ?? null}
                  onThumbnailError={handleThumbnailError}
                  onOpen={openCard}
                  dragDisabled={reordering}
                />
              ))}
            </ul>
          </SortableContext>
        </DndContext>
      )}

      {/* Rename dialog */}
      <Dialog open={renameOpen} onOpenChange={setRenameOpen}>
        <DialogContent>
          <form onSubmit={handleRename}>
            <DialogHeader>
              <DialogTitle>Rename deck</DialogTitle>
              <DialogDescription>
                Give this deck a new name.
              </DialogDescription>
            </DialogHeader>
            <div className="my-4 space-y-2">
              <Label htmlFor="deck-name">Deck name</Label>
              <Input
                id="deck-name"
                value={renameValue}
                onChange={(e) => setRenameValue(e.target.value)}
                maxLength={200}
                autoFocus
              />
            </div>
            <DialogFooter>
              <Button
                type="button"
                variant="outline"
                onClick={() => setRenameOpen(false)}
              >
                Cancel
              </Button>
              <Button type="submit" disabled={renaming}>
                {renaming ? "Saving…" : "Save"}
              </Button>
            </DialogFooter>
          </form>
        </DialogContent>
      </Dialog>

      {/* Delete confirmation */}
      <AlertDialog open={deleteOpen} onOpenChange={setDeleteOpen}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>Delete this deck?</AlertDialogTitle>
            <AlertDialogDescription>
              "{deck.name}" will be moved to trash. You can restore it within 30
              days.
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel disabled={busy}>Cancel</AlertDialogCancel>
            <AlertDialogAction
              className="bg-destructive text-destructive-foreground hover:bg-destructive/90"
              disabled={busy}
              onClick={(e) => {
                // Keep the dialog logic in our async handler; prevent the
                // default auto-close so we can show errors if it fails.
                e.preventDefault();
                void handleDelete();
              }}
            >
              {busy ? "Deleting…" : "Delete"}
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </div>
  );
}

/** Props for a single sortable card row. */
interface SortableCardRowProps {
  card: CardRecord;
  thumbnail: Thumbnail | null;
  /** Re-mints the thumbnail URL when its <img> fails to load (expired token). */
  onThumbnailError: (cardId: string, image: CardImage) => void;
  onOpen: (cardId: string) => void;
  /** Disables the drag handle while a reorder is being persisted. */
  dragDisabled?: boolean;
}

/**
 * One draggable card row. The grip handle owns the drag listeners so the rest
 * of the row remains clickable (opens the card editor).
 */
function SortableCardRow({
  card,
  thumbnail,
  onThumbnailError,
  onOpen,
  dragDisabled = false,
}: SortableCardRowProps): React.JSX.Element {
  const {
    attributes,
    listeners,
    setNodeRef,
    transform,
    transition,
    isDragging,
  } = useSortable({ id: card.id, disabled: dragDisabled });

  const style: React.CSSProperties = {
    transform: CSS.Transform.toString(transform),
    transition,
  };

  const meta = [card.time_slot, card.subjects, card.direction]
    .map((s) => s.trim())
    .filter(Boolean);

  return (
    <li
      ref={setNodeRef}
      style={style}
      className={cn(
        "flex items-center gap-3 rounded-lg border bg-card p-3 shadow-sm",
        isDragging && "z-10 opacity-80 shadow-md",
      )}
    >
      <button
        type="button"
        disabled={dragDisabled}
        className="shrink-0 cursor-grab touch-none rounded p-1 text-muted-foreground hover:bg-accent active:cursor-grabbing disabled:cursor-not-allowed disabled:opacity-50"
        aria-label="Drag to reorder"
        {...attributes}
        {...listeners}
      >
        <span aria-hidden>⠿</span>
      </button>

      <button
        type="button"
        onClick={() => onOpen(card.id)}
        className="flex min-w-0 flex-1 items-center gap-3 text-left"
      >
        {thumbnail ? (
          <img
            src={thumbnail.url}
            alt=""
            className="h-12 w-12 shrink-0 rounded-md object-cover"
            loading="lazy"
            onError={() => onThumbnailError(card.id, thumbnail.image)}
          />
        ) : (
          <div className="flex h-12 w-12 shrink-0 items-center justify-center rounded-md bg-muted text-xs text-muted-foreground">
            No img
          </div>
        )}
        <div className="min-w-0 flex-1">
          <div className="flex items-center gap-2">
            <span className="truncate font-medium">
              {card.title.trim() || "Untitled card"}
            </span>
            {card.time_slot.trim() ? (
              <Badge variant="secondary" className="shrink-0">
                {card.time_slot.trim()}
              </Badge>
            ) : null}
          </div>
          {meta.length > 0 ? (
            <p className="mt-0.5 truncate text-sm text-muted-foreground">
              {meta.join(" · ")}
            </p>
          ) : null}
        </div>
      </button>
    </li>
  );
}
