/**
 * Share dialog for a deck (M5 sharing, ARCHITECTURE.md §6 / §3.5).
 *
 * Owner-only. Lists the deck's current guests (live from Dexie via
 * `liveDeckGuests`) each with a Revoke button, and an "add by email" input +
 * Share button. Sharing is grant/revoke only — NO share links, NO QR.
 *
 * Guards before issuing a grant:
 *  - self-share: reject `email === current user's email` (FIX #4) so the owner
 *    never creates a self-grant that would trip the guest-hydration path;
 *  - duplicate: pre-check the live guest list and surface "already shared"
 *    (the server's composite-unique 400 is also handled idempotently — FIX #6 —
 *    so a race is safe, but the pre-check gives immediate feedback);
 *  - not-found: `grantGuest` throws `GuestNotFoundError` when no user matches.
 *
 * Errors surface via toast; a 401 clears the session via
 * `clearAuthOnUnauthorized`.
 */
import * as React from "react";

import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { toast } from "@/components/ui/use-toast";
import { clearAuthOnUnauthorized, useAuth } from "@/features/auth/AuthContext";
import {
  GuestNotFoundError,
  grantGuest,
  revokeGuest,
} from "@/features/decks/guestApi";
import { db } from "@/lib/db";
import { liveDeckGuests } from "@/lib/localStore";
import { useLiveQuery } from "@/lib/useLiveQuery";
import type { DeckGuest } from "@/lib/types";

export interface ShareDeckDialogProps {
  deckId: string;
  open: boolean;
  onOpenChange: (open: boolean) => void;
}

export function ShareDeckDialog({
  deckId,
  open,
  onOpenChange,
}: ShareDeckDialogProps): React.JSX.Element {
  const { user } = useAuth();
  const liveGuests = useLiveQuery<DeckGuest[]>(
    () => liveDeckGuests(db, deckId),
    [deckId],
  );
  const guests = React.useMemo(() => liveGuests ?? [], [liveGuests]);

  const [email, setEmail] = React.useState("");
  const [sharing, setSharing] = React.useState(false);
  const [revokingId, setRevokingId] = React.useState<string | null>(null);

  const handleShare = React.useCallback(
    async (event: React.FormEvent) => {
      event.preventDefault();
      const trimmed = email.trim();
      if (trimmed === "" || sharing) {
        return;
      }
      // FIX #4: never self-share. Compare case-insensitively against the
      // owner's own email.
      const myEmail = user?.email?.trim().toLowerCase() ?? "";
      if (myEmail !== "" && trimmed.toLowerCase() === myEmail) {
        toast({
          variant: "destructive",
          title: "Can't share with yourself",
          description: "You already own this deck.",
        });
        return;
      }
      setSharing(true);
      try {
        const guest = await grantGuest(deckId, trimmed);
        // Duplicate pre-check: a prior grant for this user already exists in the
        // live mirror (other than the row we just optimistically wrote).
        const already = guests.some(
          (g) => g.user === guest.user && g.id !== guest.id,
        );
        if (already) {
          // Roll back the just-written optimistic duplicate; the existing grant
          // stands. (The server's composite-unique 400 would also no-op it.)
          await revokeGuest(guest.id);
          toast({
            variant: "destructive",
            title: "Already shared",
            description: `${trimmed} already has access.`,
          });
        } else {
          toast({
            title: "Deck shared",
            description: `${trimmed} can now view this deck.`,
          });
          setEmail("");
        }
      } catch (err) {
        if (err instanceof GuestNotFoundError) {
          toast({
            variant: "destructive",
            title: "No user with that email",
            description: `No account found for ${trimmed}.`,
          });
        } else if (!clearAuthOnUnauthorized(err)) {
          toast({
            variant: "destructive",
            title: "Couldn't share deck",
            description: "Please try again.",
          });
        }
      } finally {
        setSharing(false);
      }
    },
    [deckId, email, guests, sharing, user?.email],
  );

  const handleRevoke = React.useCallback(
    async (guest: DeckGuest) => {
      setRevokingId(guest.id);
      try {
        await revokeGuest(guest.id);
        // The live query drops the row automatically.
        toast({ title: "Access revoked" });
      } catch (err) {
        if (!clearAuthOnUnauthorized(err)) {
          toast({
            variant: "destructive",
            title: "Couldn't revoke access",
            description: "Please try again.",
          });
        }
      } finally {
        setRevokingId(null);
      }
    },
    [],
  );

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Share deck</DialogTitle>
          <DialogDescription>
            Share this deck (read-only) with another user by their email.
          </DialogDescription>
        </DialogHeader>

        <form onSubmit={handleShare} className="my-2 flex items-end gap-2">
          <div className="flex-1 space-y-2">
            <Label htmlFor="share-email">Email</Label>
            <Input
              id="share-email"
              type="email"
              placeholder="person@example.com"
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              autoFocus
            />
          </div>
          <Button type="submit" disabled={sharing || email.trim() === ""}>
            {sharing ? "Sharing…" : "Share"}
          </Button>
        </form>

        <div className="space-y-2">
          <h3 className="text-sm font-medium text-muted-foreground">
            People with access
          </h3>
          {guests.length === 0 ? (
            <p className="py-2 text-sm text-muted-foreground">
              Not shared with anyone yet.
            </p>
          ) : (
            <ul className="flex flex-col gap-2">
              {guests.map((guest) => (
                <li
                  key={guest.id}
                  className="flex items-center justify-between gap-3 rounded-md border p-2"
                >
                  <span className="min-w-0 flex-1 truncate text-sm">
                    {guest.user}
                  </span>
                  <Button
                    variant="outline"
                    size="sm"
                    disabled={revokingId === guest.id}
                    onClick={() => void handleRevoke(guest)}
                  >
                    {revokingId === guest.id ? "Revoking…" : "Revoke"}
                  </Button>
                </li>
              ))}
            </ul>
          )}
        </div>
      </DialogContent>
    </Dialog>
  );
}
