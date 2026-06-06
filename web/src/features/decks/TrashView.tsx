/**
 * Trash view (route: "/trash", DESIGN.md §3.3).
 *
 * Lists soft-deleted decks (most-recently-deleted first) and lets the user
 * restore them. Permanent deletion is server-side (30-day retention sweep), so
 * this view never hard-deletes.
 */
import * as React from "react";

import { ArrowLeft } from "lucide-react";
import { Link } from "react-router-dom";

import { Button, buttonVariants } from "@/components/ui/button";
import { Card, CardHeader, CardTitle } from "@/components/ui/card";
import { toast } from "@/components/ui/use-toast";
import { clearAuthOnUnauthorized } from "@/features/auth/AuthContext";
import { listTrashedDecks, restoreDeck } from "@/features/decks/deckApi";
import { cn } from "@/lib/utils";
import type { Deck } from "@/lib/types";

/** Format an ISO datetime for display, or null when unset/unparseable. */
function formatDate(value: string): string | null {
  if (typeof value !== "string" || value === "") {
    return null;
  }
  const ms = Date.parse(value);
  if (Number.isNaN(ms)) {
    return null;
  }
  return new Date(ms).toLocaleDateString(undefined, {
    year: "numeric",
    month: "short",
    day: "numeric",
  });
}

export default function TrashView(): React.JSX.Element {
  const [decks, setDecks] = React.useState<Deck[]>([]);
  const [loading, setLoading] = React.useState(true);
  const [loadError, setLoadError] = React.useState<string | null>(null);
  const [restoringId, setRestoringId] = React.useState<string | null>(null);

  const refresh = React.useCallback(async (): Promise<void> => {
    try {
      const next = await listTrashedDecks();
      setDecks(next);
      setLoadError(null);
    } catch (error) {
      if (clearAuthOnUnauthorized(error)) {
        return;
      }
      setLoadError("Could not load Trash. Please try again.");
    } finally {
      setLoading(false);
    }
  }, []);

  React.useEffect(() => {
    void refresh();
  }, [refresh]);

  const handleRestore = async (deck: Deck): Promise<void> => {
    setRestoringId(deck.id);
    try {
      await restoreDeck(deck.id);
      setDecks((prev) => prev.filter((d) => d.id !== deck.id));
      toast({
        title: "Deck restored",
        description: `“${deck.name}” is back in your decks.`,
      });
    } catch (error) {
      if (!clearAuthOnUnauthorized(error)) {
        toast({
          variant: "destructive",
          title: "Could not restore deck",
          description: "Something went wrong. Please try again.",
        });
      }
    } finally {
      setRestoringId(null);
    }
  };

  return (
    <main className="mx-auto flex w-full max-w-5xl flex-col gap-6 p-6">
      <header className="flex flex-col gap-2">
        <Link
          to="/"
          className={cn(
            buttonVariants({ variant: "ghost", size: "sm" }),
            "w-fit -ml-2",
          )}
        >
          <ArrowLeft className="h-4 w-4" />
          Back to decks
        </Link>
        <div>
          <h1 className="text-2xl font-semibold tracking-tight">Trash</h1>
          <p className="text-sm text-muted-foreground">
            Deleted decks are kept for 30 days, then permanently removed.
          </p>
        </div>
      </header>

      {loading ? (
        <p className="py-12 text-center text-sm text-muted-foreground">
          Loading Trash…
        </p>
      ) : loadError !== null ? (
        <div className="flex flex-col items-center gap-3 py-12">
          <p className="text-sm text-destructive">{loadError}</p>
          <Button variant="outline" onClick={() => void refresh()}>
            Retry
          </Button>
        </div>
      ) : decks.length === 0 ? (
        <p className="py-16 text-center text-sm text-muted-foreground">
          Trash is empty.
        </p>
      ) : (
        <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-3">
          {decks.map((deck) => {
            const deletedLabel = formatDate(deck.deleted_at);
            return (
              <Card key={deck.id} className="flex flex-col">
                <CardHeader className="flex-1">
                  <CardTitle className="truncate">{deck.name}</CardTitle>
                  <p className="text-sm text-muted-foreground">
                    {deletedLabel !== null
                      ? `Deleted ${deletedLabel}`
                      : "Deleted"}
                  </p>
                </CardHeader>
                <div className="px-6 pb-6">
                  <Button
                    variant="outline"
                    size="sm"
                    disabled={restoringId === deck.id}
                    onClick={() => void handleRestore(deck)}
                  >
                    {restoringId === deck.id ? "Restoring…" : "Restore"}
                  </Button>
                </div>
              </Card>
            );
          })}
        </div>
      )}
    </main>
  );
}
