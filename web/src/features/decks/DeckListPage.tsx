/**
 * Deck list — the home screen (route: "/", DESIGN.md §3.3).
 *
 * Loads the user's decks, groups them into Upcoming / Undated / Past, and
 * filters by a name search. A "New deck" dialog creates a deck and navigates
 * into it. Each deck tile (DeckCard) exposes rename / duplicate / delete.
 *
 * For M1 mutations call deckApi directly; the list is refetched after each
 * mutation to keep grouping/sorting consistent with the server.
 */
import * as React from "react";

import { Plus, Trash2 } from "lucide-react";
import { Link, useNavigate } from "react-router-dom";

import { Badge } from "@/components/ui/badge";
import { Button, buttonVariants } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { toast } from "@/components/ui/use-toast";
import { clearAuthOnUnauthorized } from "@/features/auth/AuthContext";
import {
  createDeck,
  duplicateDeck,
  listDecks,
  renameDeck,
  softDeleteDeck,
} from "@/features/decks/deckApi";
import { DeckCard } from "@/features/decks/DeckCard";
import { ThemeToggle } from "@/components/theme/ThemeToggle";
import { groupDecks, searchDecks } from "@/features/decks/deckGrouping";
import { listCards } from "@/features/cards/cardApi";
import { imageDisplayUrl, listCardImages } from "@/features/images/imageApi";
import { cn } from "@/lib/utils";
import type { Deck } from "@/lib/types";

/**
 * Convert an HTML `<input type="date">` value (YYYY-MM-DD) to an ISO string.
 *
 * The date picker yields a calendar day with no time/zone. We anchor it to
 * **local** midnight (building the Date from its parts) rather than
 * `Date.parse`, which treats a bare YYYY-MM-DD as UTC midnight. This keeps the
 * write side in the same timezone basis as `deckGrouping.startOfDayMs` (also
 * local midnight) — otherwise a deck shot "today" lands in Past for any user
 * west of UTC. See the M1 adversarial review (grouping-today-boundary).
 */
function dateInputToIso(value: string): string {
  const trimmed = value.trim();
  if (trimmed === "") {
    return "";
  }
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(trimmed);
  if (match === null) {
    return "";
  }
  const [, year, month, day] = match;
  const local = new Date(Number(year), Number(month) - 1, Number(day));
  if (Number.isNaN(local.getTime())) {
    return "";
  }
  return local.toISOString();
}

interface DeckSectionProps {
  title: string;
  decks: Deck[];
  /** Map of deck id → resolved auto-thumbnail URL (DESIGN.md §3.3). */
  thumbnails: Record<string, string | null>;
  /** Id of the deck with an in-flight duplicate/delete mutation, if any. */
  pendingDeckId: string | null;
  onOpen: (deck: Deck) => void;
  onRename: (deck: Deck) => void;
  onDuplicate: (deck: Deck) => void;
  onDelete: (deck: Deck) => void;
}

function DeckSection({
  title,
  decks,
  thumbnails,
  pendingDeckId,
  onOpen,
  onRename,
  onDuplicate,
  onDelete,
}: DeckSectionProps): React.JSX.Element | null {
  if (decks.length === 0) {
    return null;
  }
  return (
    <section className="flex flex-col gap-3">
      <div className="flex items-center gap-2">
        <h2 className="text-sm font-semibold uppercase tracking-wide text-muted-foreground">
          {title}
        </h2>
        <Badge variant="secondary">{decks.length}</Badge>
      </div>
      <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-3">
        {decks.map((deck) => (
          <DeckCard
            key={deck.id}
            deck={deck}
            thumbnailUrl={thumbnails[deck.id] ?? null}
            pending={pendingDeckId === deck.id}
            onOpen={onOpen}
            onRename={onRename}
            onDuplicate={onDuplicate}
            onDelete={onDelete}
          />
        ))}
      </div>
    </section>
  );
}

/**
 * Resolve a deck's auto-thumbnail (DESIGN.md §3.3): the first image of the
 * deck's first (lowest-position) card, as a display URL. Returns `null` when
 * the deck has no cards, the first card has no images, or anything fails — the
 * tile then renders its placeholder. Best-effort and isolated per deck so one
 * failing deck never blocks the others.
 */
async function resolveDeckThumbnail(deckId: string): Promise<string | null> {
  try {
    const cards = await listCards(deckId);
    const firstCard = cards[0];
    if (!firstCard) {
      return null;
    }
    const images = await listCardImages(firstCard.id);
    const firstImage = images[0];
    if (!firstImage) {
      return null;
    }
    return await imageDisplayUrl(firstImage, { thumb: "400x300" });
  } catch {
    return null;
  }
}

export default function DeckListPage(): React.JSX.Element {
  const navigate = useNavigate();

  const [decks, setDecks] = React.useState<Deck[]>([]);
  const [thumbnails, setThumbnails] = React.useState<
    Record<string, string | null>
  >({});
  const [loading, setLoading] = React.useState(true);
  const [loadError, setLoadError] = React.useState<string | null>(null);
  const [query, setQuery] = React.useState("");

  // Create-deck dialog state.
  const [createOpen, setCreateOpen] = React.useState(false);
  const [createName, setCreateName] = React.useState("");
  const [createDate, setCreateDate] = React.useState("");
  const [creating, setCreating] = React.useState(false);

  // Rename dialog state.
  const [renameTarget, setRenameTarget] = React.useState<Deck | null>(null);
  const [renameValue, setRenameValue] = React.useState("");
  const [renaming, setRenaming] = React.useState(false);

  // Id of the deck with an in-flight duplicate/delete mutation. Used to disable
  // that deck's destructive actions until the list refreshes, so the user can't
  // re-fire a non-idempotent mutation (e.g. Duplicate) on the same deck while
  // it is still rendered. Mirrors TrashView's `restoringId` guard.
  const [pendingDeckId, setPendingDeckId] = React.useState<string | null>(null);

  const refresh = React.useCallback(async (): Promise<void> => {
    try {
      const next = await listDecks();
      setDecks(next);
      setLoadError(null);
    } catch (error) {
      if (clearAuthOnUnauthorized(error)) {
        return;
      }
      setLoadError("Could not load your decks. Please try again.");
    } finally {
      setLoading(false);
    }
  }, []);

  React.useEffect(() => {
    void refresh();
  }, [refresh]);

  // Best-effort: resolve each deck's auto-thumbnail (first image of first card,
  // DESIGN.md §3.3) once the decks load. Isolated per deck and cancellable so a
  // refetch never commits stale URLs.
  React.useEffect(() => {
    if (decks.length === 0) {
      setThumbnails({});
      return;
    }
    let cancelled = false;
    void (async () => {
      const entries = await Promise.all(
        decks.map(
          async (deck): Promise<[string, string | null]> => [
            deck.id,
            await resolveDeckThumbnail(deck.id),
          ],
        ),
      );
      if (!cancelled) {
        setThumbnails(Object.fromEntries(entries));
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [decks]);

  const grouped = React.useMemo(() => {
    const filtered = searchDecks(decks, query);
    return groupDecks(filtered, new Date());
  }, [decks, query]);

  const visibleCount =
    grouped.upcoming.length + grouped.undated.length + grouped.past.length;

  const openDeck = React.useCallback(
    (deck: Deck): void => {
      navigate(`/decks/${deck.id}`);
    },
    [navigate],
  );

  const handleCreate = async (
    event: React.FormEvent<HTMLFormElement>,
  ): Promise<void> => {
    event.preventDefault();
    const name = createName.trim();
    if (name === "" || creating) {
      return;
    }
    setCreating(true);
    try {
      const deck = await createDeck({
        name,
        shoot_date: dateInputToIso(createDate),
      });
      setCreateOpen(false);
      setCreateName("");
      setCreateDate("");
      navigate(`/decks/${deck.id}`);
    } catch (error) {
      if (!clearAuthOnUnauthorized(error)) {
        toast({
          variant: "destructive",
          title: "Could not create deck",
          description: "Something went wrong. Please try again.",
        });
      }
    } finally {
      setCreating(false);
    }
  };

  const startRename = React.useCallback((deck: Deck): void => {
    setRenameTarget(deck);
    setRenameValue(deck.name);
  }, []);

  const handleRename = async (
    event: React.FormEvent<HTMLFormElement>,
  ): Promise<void> => {
    event.preventDefault();
    const name = renameValue.trim();
    if (renameTarget === null || name === "" || renaming) {
      return;
    }
    setRenaming(true);
    try {
      await renameDeck(renameTarget.id, name);
      setRenameTarget(null);
      await refresh();
    } catch (error) {
      if (!clearAuthOnUnauthorized(error)) {
        toast({
          variant: "destructive",
          title: "Could not rename deck",
          description: "Something went wrong. Please try again.",
        });
      }
    } finally {
      setRenaming(false);
    }
  };

  const handleDuplicate = React.useCallback(
    async (deck: Deck): Promise<void> => {
      // Guard against a second mutation on a deck whose previous duplicate/
      // delete is still in flight — duplicateDeck is not idempotent.
      if (pendingDeckId !== null) {
        return;
      }
      setPendingDeckId(deck.id);
      try {
        const copy = await duplicateDeck(deck.id);
        await refresh();
        toast({
          title: "Deck duplicated",
          description: `Created “${copy.name}”.`,
        });
      } catch (error) {
        if (!clearAuthOnUnauthorized(error)) {
          toast({
            variant: "destructive",
            title: "Could not duplicate deck",
            description: "Something went wrong. Please try again.",
          });
        }
      } finally {
        setPendingDeckId(null);
      }
    },
    [pendingDeckId, refresh],
  );

  const handleDelete = React.useCallback(
    async (deck: Deck): Promise<void> => {
      // Guard against re-firing while a mutation for any deck is in flight.
      if (pendingDeckId !== null) {
        return;
      }
      setPendingDeckId(deck.id);
      try {
        await softDeleteDeck(deck.id);
        await refresh();
        toast({
          title: "Deck moved to Trash",
          description: `“${deck.name}” can be restored for 30 days.`,
        });
      } catch (error) {
        if (!clearAuthOnUnauthorized(error)) {
          toast({
            variant: "destructive",
            title: "Could not delete deck",
            description: "Something went wrong. Please try again.",
          });
        }
      } finally {
        setPendingDeckId(null);
      }
    },
    [pendingDeckId, refresh],
  );

  return (
    <main className="mx-auto flex w-full max-w-5xl flex-col gap-6 p-6">
      <header className="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
        <div>
          <h1 className="text-2xl font-semibold tracking-tight">Decks</h1>
          <p className="text-sm text-muted-foreground">
            Your shoot decks, grouped by date.
          </p>
        </div>
        <div className="flex items-center gap-2">
          <ThemeToggle />
          <Link
            to="/trash"
            className={cn(buttonVariants({ variant: "outline" }))}
          >
            <Trash2 className="h-4 w-4" />
            Trash
          </Link>
          <Button onClick={() => setCreateOpen(true)}>
            <Plus className="h-4 w-4" />
            New deck
          </Button>
        </div>
      </header>

      <Input
        type="search"
        placeholder="Search decks by name…"
        value={query}
        onChange={(e) => setQuery(e.target.value)}
        aria-label="Search decks by name"
      />

      {loading ? (
        <p className="py-12 text-center text-sm text-muted-foreground">
          Loading decks…
        </p>
      ) : loadError !== null ? (
        <div className="flex flex-col items-center gap-3 py-12">
          <p className="text-sm text-destructive">{loadError}</p>
          <Button variant="outline" onClick={() => void refresh()}>
            Retry
          </Button>
        </div>
      ) : decks.length === 0 ? (
        <div className="flex flex-col items-center gap-3 py-16 text-center">
          <p className="text-sm text-muted-foreground">
            No decks yet. Create your first deck to get started.
          </p>
          <Button onClick={() => setCreateOpen(true)}>
            <Plus className="h-4 w-4" />
            New deck
          </Button>
        </div>
      ) : visibleCount === 0 ? (
        <p className="py-12 text-center text-sm text-muted-foreground">
          No decks match “{query.trim()}”.
        </p>
      ) : (
        <div className="flex flex-col gap-8">
          <DeckSection
            title="Upcoming"
            decks={grouped.upcoming}
            thumbnails={thumbnails}
            pendingDeckId={pendingDeckId}
            onOpen={openDeck}
            onRename={startRename}
            onDuplicate={handleDuplicate}
            onDelete={handleDelete}
          />
          <DeckSection
            title="Undated"
            decks={grouped.undated}
            thumbnails={thumbnails}
            pendingDeckId={pendingDeckId}
            onOpen={openDeck}
            onRename={startRename}
            onDuplicate={handleDuplicate}
            onDelete={handleDelete}
          />
          <DeckSection
            title="Past"
            decks={grouped.past}
            thumbnails={thumbnails}
            pendingDeckId={pendingDeckId}
            onOpen={openDeck}
            onRename={startRename}
            onDuplicate={handleDuplicate}
            onDelete={handleDelete}
          />
        </div>
      )}

      {/* Create deck dialog */}
      <Dialog open={createOpen} onOpenChange={setCreateOpen}>
        <DialogContent>
          <form onSubmit={handleCreate} className="flex flex-col gap-4">
            <DialogHeader>
              <DialogTitle>New deck</DialogTitle>
              <DialogDescription>
                Name your shoot. You can add a shoot date now or later.
              </DialogDescription>
            </DialogHeader>
            <div className="flex flex-col gap-1.5">
              <Label htmlFor="deck-name">Name</Label>
              <Input
                id="deck-name"
                value={createName}
                onChange={(e) => setCreateName(e.target.value)}
                placeholder="e.g. Smith Wedding"
                maxLength={200}
                disabled={creating}
                required
                autoFocus
              />
            </div>
            <div className="flex flex-col gap-1.5">
              <Label htmlFor="deck-date">Shoot date (optional)</Label>
              <Input
                id="deck-date"
                type="date"
                value={createDate}
                onChange={(e) => setCreateDate(e.target.value)}
                disabled={creating}
              />
            </div>
            <DialogFooter>
              <Button
                type="submit"
                disabled={creating || createName.trim() === ""}
              >
                {creating ? "Creating…" : "Create deck"}
              </Button>
            </DialogFooter>
          </form>
        </DialogContent>
      </Dialog>

      {/* Rename deck dialog */}
      <Dialog
        open={renameTarget !== null}
        onOpenChange={(open) => {
          if (!open) {
            setRenameTarget(null);
          }
        }}
      >
        <DialogContent>
          <form onSubmit={handleRename} className="flex flex-col gap-4">
            <DialogHeader>
              <DialogTitle>Rename deck</DialogTitle>
              <DialogDescription>
                Give this deck a new name.
              </DialogDescription>
            </DialogHeader>
            <div className="flex flex-col gap-1.5">
              <Label htmlFor="rename-deck">Name</Label>
              <Input
                id="rename-deck"
                value={renameValue}
                onChange={(e) => setRenameValue(e.target.value)}
                maxLength={200}
                disabled={renaming}
                required
                autoFocus
              />
            </div>
            <DialogFooter>
              <Button
                type="submit"
                disabled={renaming || renameValue.trim() === ""}
              >
                {renaming ? "Saving…" : "Save"}
              </Button>
            </DialogFooter>
          </form>
        </DialogContent>
      </Dialog>
    </main>
  );
}
