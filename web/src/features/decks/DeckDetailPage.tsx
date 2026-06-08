/**
 * Deck detail page (route `/decks/:id`).
 *
 * Shows a single deck's cards as an ordered, drag-droppable list. As of M3 the
 * deck and its cards are read from Dexie via live queries (`liveDeck`,
 * `liveCards`), so sync / realtime writes re-render the UI automatically.
 * Reordering writes the new positions to Dexie + the outbox via
 * `cardApi.reorderCards`; the live query reflects the new order immediately, so
 * there is no manual optimistic snapshot to revert — a failed/rolled-back
 * reorder reconciles back through the live query.
 *
 * The header shows the deck name with inline rename, a back link to the deck
 * list ("/"), and a rename / share / export / delete menu (Duplicate lives in
 * the deck list, not here). Each card row shows its
 * title / time slot / subjects / direction plus a thumbnail (the first card
 * image, via `<OfflineImage>` so a pinned deck renders offline). "Add card"
 * creates a card and opens the card editor; clicking a row opens the editor.
 */
import * as React from "react";
import { Link, useNavigate, useParams } from "react-router-dom";
import { Trash2 } from "lucide-react";

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

import { clearAuthOnUnauthorized, useAuth } from "@/features/auth/AuthContext";
import {
  createCard,
  reorderCards,
  softDeleteCard,
} from "@/features/cards/cardApi";
import { renameDeck, softDeleteDeck } from "@/features/decks/deckApi";
import { ShareDeckDialog } from "@/features/decks/ShareDeckDialog";
import { OfflineToggle } from "@/features/offline/OfflineToggle";
import { OfflineImage } from "@/features/offline/OfflineImage";
import { imageDisplayUrl } from "@/features/images/imageApi";
import { db } from "@/lib/db";
import { liveCardImages, liveCards, liveDeck } from "@/lib/localStore";
import { useLiveQuery } from "@/lib/useLiveQuery";
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
 * Per-card thumbnail state keyed by card id: the FIRST card image record (or
 * `null` when the card has no images). The actual source resolution — pinned
 * blob vs. token URL, plus expired-token retry — is owned by `<OfflineImage>`,
 * so this map only needs to identify which image to show.
 */
type ThumbnailMap = Record<string, CardImage | null>;

export default function DeckDetailPage(): React.JSX.Element {
  const { id } = useParams<{ id: string }>();
  const navigate = useNavigate();
  const { user } = useAuth();

  // Local-first reads: the deck and its cards come from Dexie via live queries,
  // so sync / realtime writes re-render the UI automatically. `undefined` =
  // loading; `null`/missing deck = not-found (or soft-deleted).
  // `liveDeck` resolves to `null` for a missing/soft-deleted deck; the live
  // query hook returns `undefined` only while still loading. Mapping not-found
  // to `null` (not `undefined`) lets us distinguish "loading" from "not found".
  const liveDeckRow = useLiveQuery<Deck | null>(
    () => (id ? liveDeck(db, id).then((d) => d ?? null) : Promise.resolve(null)),
    [id],
  );
  const liveCardRows = useLiveQuery(
    () => (id ? liveCards(db, id) : Promise.resolve([])),
    [id],
  );
  const deck: Deck | null = liveDeckRow ?? null;
  const cards = React.useMemo<CardRecord[]>(
    () => liveCardRows ?? [],
    [liveCardRows],
  );
  const loading = liveDeckRow === undefined || liveCardRows === undefined;

  // Stable identity of the card SET (sorted ids) for the thumbnail effect.
  // Dexie's `useLiveQuery` hands back a NEW `cards` array reference on every
  // write to the cards table — including reorders (which only rewrite
  // `position`) and per-card field edits that don't change which cards exist.
  // Keying the thumbnail-build effect off this order-independent string
  // (instead of the `cards` array identity) means a reorder or card edit no
  // longer re-queries every card's images; the effect only re-runs when a card
  // is actually added or removed.
  const cardIdsKey = React.useMemo(
    () =>
      cards
        .map((c) => c.id)
        .sort()
        .join(","),
    [cards],
  );

  const [thumbnails, setThumbnails] = React.useState<ThumbnailMap>({});

  // True while a `reorderCards` write is in flight. We block starting a new
  // reorder until the previous one settles so two restripes can't interleave.
  const [reordering, setReordering] = React.useState(false);

  const [renameOpen, setRenameOpen] = React.useState(false);
  const [renameValue, setRenameValue] = React.useState("");
  const [renaming, setRenaming] = React.useState(false);

  const [deleteOpen, setDeleteOpen] = React.useState(false);
  const [shareOpen, setShareOpen] = React.useState(false);
  const [busy, setBusy] = React.useState(false);
  const [creating, setCreating] = React.useState(false);
  const [exporting, setExporting] = React.useState(false);

  // The card pending delete-confirmation (inline from the list), plus the
  // in-flight flag for that delete.
  const [cardToDelete, setCardToDelete] = React.useState<CardRecord | null>(
    null,
  );
  const [deletingCard, setDeletingCard] = React.useState(false);

  const sensors = useSensors(
    useSensor(PointerSensor, { activationConstraint: { distance: 4 } }),
    useSensor(KeyboardSensor, {
      coordinateGetter: sortableKeyboardCoordinates,
    }),
  );

  // Best-effort: pick each card's first-image record from Dexie. Re-runs only
  // when the set of card ids changes (a card added/removed), NOT on every
  // reorder or per-card edit — Dexie's live query hands back a fresh `cards`
  // array reference on any cards-table write, so depending on `cardIdsKey`
  // (a stable string of ids) instead of the `cards` array identity avoids
  // re-querying every card's images for position-only or field-only changes.
  // `<OfflineImage>` owns the actual source resolution (pinned blob vs. token
  // URL) and the expired-token retry, so we only need the image record here.
  React.useEffect(() => {
    let cancelled = false;
    const cardIds = cardIdsKey ? cardIdsKey.split(",") : [];
    (async () => {
      const thumbEntries = await Promise.all(
        cardIds.map(async (cardId): Promise<[string, CardImage | null]> => {
          try {
            const imgs: CardImage[] = await liveCardImages(db, cardId);
            return [cardId, imgs[0] ?? null];
          } catch {
            return [cardId, null];
          }
        }),
      );
      if (!cancelled) {
        setThumbnails(Object.fromEntries(thumbEntries));
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [cardIdsKey]);

  // Guests view the deck read-only (DESIGN.md §6: "Guests cannot edit cards,
  // reorder, or share."). Computed here (not after the early returns) so the
  // mutation callbacks below can guard on it. `deck` may be null while loading;
  // the early returns below bail before any owner-only UI renders.
  const isOwner = deck?.owner === user?.id;

  const handleDragEnd = React.useCallback(
    (event: DragEndEvent) => {
      // Guests cannot reorder (DESIGN.md §6). Refuse to persist a drop even if a
      // drag somehow fires; the drag handles are also disabled for guests.
      if (!isOwner) {
        return;
      }
      // Serialize persistence: ignore drops while a reorder write is still in
      // flight so two restripes can't interleave.
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
      setReordering(true);

      const orderedIds = reordered.map((c) => c.id);
      // Pass the pre-reorder positions so reorderCards can skip cards that did
      // not actually move, avoiding needless client_updated_at bumps that could
      // clobber concurrent edits under last-write-wins (ARCHITECTURE.md §4.3).
      // The optimistic order is written to Dexie inside reorderCards, so the
      // live card query re-renders the new order without a local snapshot.
      const currentPositions = new Map(cards.map((c) => [c.id, c.position]));
      reorderCards(id, orderedIds, currentPositions)
        .catch((err) => {
          clearAuthOnUnauthorized(err);
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
    [cards, id, isOwner, reordering],
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
        await renameDeck(deck.id, next);
        // The live deck query reflects the new name automatically.
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

  // Export the deck to a downloaded PDF (M6). The heavy `@react-pdf/renderer`
  // module is loaded ONLY here, via dynamic import, so it is code-split out of
  // the initial app chunk (most sessions never export). `exportDeckPdf` reads
  // from Dexie (local-first), so a pinned deck exports offline. A fail-soft
  // resolver may drop unreachable images; we surface that count in the toast.
  const handleExport = React.useCallback(async () => {
    if (!deck) {
      return;
    }
    setExporting(true);
    try {
      const { exportDeckPdf } = await import("@/features/export/exportDeckPdf");
      const { droppedImages } = await exportDeckPdf(deck.id, { db });
      toast({
        title: "PDF exported",
        description:
          droppedImages > 0
            ? `${droppedImages} ${droppedImages === 1 ? "image" : "images"} unavailable and omitted.`
            : deck.name,
      });
    } catch (err) {
      clearAuthOnUnauthorized(err);
      toast({
        variant: "destructive",
        title: "Export failed",
        description: "Couldn't export this deck. Please try again.",
      });
    } finally {
      setExporting(false);
    }
  }, [deck]);

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
    // Guests cannot add cards (DESIGN.md §6). The button is hidden for guests;
    // this guard backstops the affordance being hidden in the UI.
    if (!id || !isOwner) {
      return;
    }
    setCreating(true);
    try {
      const card = await createCard(id, { title: "Untitled card" });
      // The live card query picks up the optimistic row; navigate to its editor.
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
  }, [id, isOwner, navigate]);

  const openCard = React.useCallback(
    (cardId: string) => {
      if (!id) {
        return;
      }
      navigate(`/decks/${id}/cards/${cardId}`);
    },
    [id, navigate],
  );

  // Soft-delete a card directly from the list (after confirmation). The live
  // card query drops the row once `deleted_at` is set. Never hard-deletes
  // (DESIGN.md soft-delete model).
  const handleDeleteCard = React.useCallback(async () => {
    // Guests cannot delete cards (DESIGN.md §6). The per-row delete button is
    // hidden for guests; this guard backstops that.
    if (!cardToDelete || !isOwner) {
      return;
    }
    setDeletingCard(true);
    try {
      await softDeleteCard(cardToDelete.id);
      toast({ title: "Card deleted" });
      setCardToDelete(null);
    } catch (err) {
      clearAuthOnUnauthorized(err);
      toast({
        variant: "destructive",
        title: "Delete failed",
        description: "Couldn't delete this card. Please try again.",
      });
    } finally {
      setDeletingCard(false);
    }
  }, [cardToDelete, isOwner]);

  if (loading) {
    return (
      <div className="mx-auto w-full max-w-3xl px-4 py-10">
        <p className="text-sm text-muted-foreground">Loading deck…</p>
      </div>
    );
  }

  if (!deck) {
    return (
      <div className="mx-auto w-full max-w-3xl px-4 py-10">
        <Link to="/" className="text-sm text-muted-foreground hover:underline">
          ← Back to decks
        </Link>
        <p className="mt-6 text-sm text-destructive">Deck not found.</p>
      </div>
    );
  }

  // Sharing/editing affordances are owner-only; a guest views the deck
  // read-only (M5/DESIGN.md §6). The deck list still shows guests their shared
  // decks, but Add-card, reorder, per-card delete, Rename/Delete/Share are all
  // hidden for non-owners. `isOwner` is computed above the early returns so the
  // mutation callbacks can guard on it; here `deck` is guaranteed non-null.
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
          <OfflineToggle deckId={deck.id} />
          {isOwner ? (
            <Button onClick={handleAddCard} disabled={creating}>
              {creating ? "Adding…" : "Add card"}
            </Button>
          ) : null}
          <DropdownMenu>
            <DropdownMenuTrigger asChild>
              <Button variant="outline" size="icon" aria-label="Deck options">
                <span aria-hidden>⋯</span>
              </Button>
            </DropdownMenuTrigger>
            <DropdownMenuContent align="end">
              {isOwner ? (
                <>
                  <DropdownMenuItem onSelect={openRename}>
                    Rename
                  </DropdownMenuItem>
                  <DropdownMenuItem onSelect={() => setShareOpen(true)}>
                    Share
                  </DropdownMenuItem>
                </>
              ) : null}
              <DropdownMenuItem
                aria-label="Export PDF"
                data-testid="export-pdf"
                onSelect={(e) => {
                  // Keep the menu's default close behaviour but run the async
                  // export off the event tick; `disabled` guards double-fire.
                  e.preventDefault();
                  void handleExport();
                }}
                disabled={exporting}
              >
                {exporting ? "Exporting…" : "Export as PDF"}
              </DropdownMenuItem>
              {isOwner ? (
                <>
                  <DropdownMenuSeparator />
                  <DropdownMenuItem
                    className="text-destructive focus:text-destructive"
                    onSelect={() => setDeleteOpen(true)}
                  >
                    Delete
                  </DropdownMenuItem>
                </>
              ) : null}
            </DropdownMenuContent>
          </DropdownMenu>
        </div>
      </header>

      {cards.length === 0 ? (
        <div className="rounded-lg border border-dashed py-16 text-center">
          <p className="text-sm text-muted-foreground">No cards yet.</p>
          {isOwner ? (
            <Button className="mt-4" onClick={handleAddCard} disabled={creating}>
              Add your first card
            </Button>
          ) : null}
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
                  onOpen={openCard}
                  onDelete={setCardToDelete}
                  // Guests view read-only: no drag handle, no delete button
                  // (DESIGN.md §6). Owners get full mutation affordances.
                  canEdit={isOwner}
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

      {/* Share dialog (owner-only) */}
      {isOwner ? (
        <ShareDeckDialog
          deckId={deck.id}
          open={shareOpen}
          onOpenChange={setShareOpen}
        />
      ) : null}

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

      {/* Card delete confirmation (inline from the list) */}
      <AlertDialog
        open={cardToDelete !== null}
        onOpenChange={(open) => {
          if (!open && !deletingCard) {
            setCardToDelete(null);
          }
        }}
      >
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>Delete this card?</AlertDialogTitle>
            <AlertDialogDescription>
              "{cardToDelete?.title.trim() || "Untitled card"}" will be removed
              from the deck.
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel disabled={deletingCard}>
              Cancel
            </AlertDialogCancel>
            <AlertDialogAction
              className="bg-destructive text-destructive-foreground hover:bg-destructive/90"
              disabled={deletingCard}
              onClick={(e) => {
                e.preventDefault();
                void handleDeleteCard();
              }}
            >
              {deletingCard ? "Deleting…" : "Delete"}
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
  /** The card's first image record, or null when it has none. */
  thumbnail: CardImage | null;
  onOpen: (cardId: string) => void;
  /** Request inline deletion of this card (opens a confirmation). */
  onDelete: (card: CardRecord) => void;
  /**
   * Whether the current viewer may mutate this card. Guests (read-only, per
   * DESIGN.md §6) get `false`: no drag handle and no delete button. The row
   * stays clickable so guests can still view the card.
   */
  canEdit: boolean;
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
  onOpen,
  onDelete,
  canEdit,
  dragDisabled = false,
}: SortableCardRowProps): React.JSX.Element {
  // Guests cannot reorder (DESIGN.md §6): disable the sortable for non-owners as
  // well as while a reorder write is in flight.
  const {
    attributes,
    listeners,
    setNodeRef,
    transform,
    transition,
    isDragging,
  } = useSortable({ id: card.id, disabled: dragDisabled || !canEdit });

  const style: React.CSSProperties = {
    transform: CSS.Transform.toString(transform),
    transition,
  };

  const meta = [card.time_slot, card.subjects, card.direction]
    .map((s) => s.trim())
    .filter(Boolean);

  const cardLabel = card.title.trim() || "Untitled card";

  return (
    <li
      ref={setNodeRef}
      style={style}
      className={cn(
        "flex items-center gap-3 rounded-lg border bg-card p-3 shadow-sm",
        isDragging && "z-10 opacity-80 shadow-md",
      )}
    >
      {canEdit ? (
        <button
          type="button"
          disabled={dragDisabled}
          className="shrink-0 cursor-grab touch-none rounded p-1 text-muted-foreground hover:bg-accent active:cursor-grabbing disabled:cursor-not-allowed disabled:opacity-50"
          // Name the handle by its target card. The keyboard alternative to the
          // pointer drag is fully handled by dnd-kit's KeyboardSensor: spreading
          // `attributes` adds `aria-roledescription="sortable"` and an
          // `aria-describedby` pointing at dnd-kit's built-in screen-reader
          // instructions ("press space bar to pick up…, arrow keys to move…"),
          // so we don't supply our own — `attributes` is spread last so it wins.
          aria-label={`Reorder ${cardLabel}`}
          {...attributes}
          {...listeners}
        >
          <span aria-hidden>⠿</span>
        </button>
      ) : null}

      <button
        type="button"
        onClick={() => onOpen(card.id)}
        className="flex min-w-0 flex-1 items-center gap-3 text-left"
      >
        {thumbnail ? (
          <OfflineImage
            image={thumbnail}
            thumb="200x200"
            networkUrl={imageDisplayUrl}
            className="h-12 w-12 shrink-0 rounded-md object-cover"
            loading="lazy"
            fallback={
              <div className="h-12 w-12 shrink-0 animate-pulse rounded-md bg-muted" />
            }
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

      {canEdit ? (
        <button
          type="button"
          onClick={() => onDelete(card)}
          className="shrink-0 rounded p-2 text-muted-foreground hover:bg-destructive/10 hover:text-destructive"
          aria-label={`Delete ${cardLabel}`}
        >
          <Trash2 className="h-4 w-4" />
        </button>
      ) : null}
    </li>
  );
}
