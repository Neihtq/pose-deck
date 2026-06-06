/**
 * Card editor page (DESIGN.md §3.1).
 *
 * A routed full-page form to create or edit a single card in a deck. Mounted at:
 *   - /decks/:deckId/cards/new        — create mode (no `cardId`)
 *   - /decks/:deckId/cards/:cardId    — edit mode
 *
 * Fields: title (required, ≤200 per ARCHITECTURE.md §3.3), time_slot, subjects,
 * direction, notes. Plus an image section (0–5) backed by the foundation image
 * pipeline: existing images render with delete buttons, an "Add image" file
 * input and clipboard paste both upload via `useImageUpload`, and the 5-image
 * cap is enforced in the UI.
 *
 * Images attach to an existing card record, so in create mode the image section
 * is disabled until the card has been saved (which transitions the page into
 * edit mode by navigating to the new card's route).
 *
 * On save → createCard/updateCard, then navigate back to the deck. Delete →
 * softDeleteCard (never hard-delete).
 */
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useNavigate, useParams } from "react-router-dom";
import { ImagePlus, Loader2, Trash2, X } from "lucide-react";

import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import { Badge } from "@/components/ui/badge";
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
import { toast } from "@/components/ui/use-toast";
import { cn } from "@/lib/utils";

import { collections } from "@/lib/pocketbase";
import type { Card, CardImage } from "@/lib/types";

import { clearAuthOnUnauthorized } from "@/features/auth/AuthContext";

import {
  type CardFields,
  createCard,
  softDeleteCard,
  updateCard,
} from "@/features/cards/cardApi";
import {
  MAX_IMAGES_PER_CARD,
  deleteCardImage,
  imageDisplayUrl,
  listCardImages,
} from "@/features/images/imageApi";
import { useImageUpload } from "@/features/images/useImageUpload";

// Product cap for card titles: DESIGN.md §3.1 specifies "≤60 chars". The DB
// field (ARCHITECTURE.md §3.3 / PocketBase `cards.title`) allows up to 200 as
// headroom, but the *product* constraint is 60 — titles are short shot labels,
// not paragraphs — and the product spec governs UI field limits. Keep this at
// 60; see regression test in __tests__/CardEditorTitleLimit.test.tsx.
const TITLE_MAX = 60;

/** Empty form state for create mode. */
const EMPTY_FORM: Required<CardFields> = {
  title: "",
  time_slot: "",
  subjects: "",
  direction: "",
  notes: "",
};

function formFromCard(card: Card): Required<CardFields> {
  return {
    title: card.title ?? "",
    time_slot: card.time_slot ?? "",
    subjects: card.subjects ?? "",
    direction: card.direction ?? "",
    notes: card.notes ?? "",
  };
}

export default function CardEditor(): JSX.Element {
  const navigate = useNavigate();
  const { deckId, cardId } = useParams<{ deckId: string; cardId?: string }>();
  const isEdit = Boolean(cardId);

  const [form, setForm] = useState<Required<CardFields>>(EMPTY_FORM);
  const [images, setImages] = useState<CardImage[]>([]);
  // Resolved (token-carrying) display URLs keyed by image id; populated async.
  const [imageUrls, setImageUrls] = useState<Record<string, string>>({});
  const [loading, setLoading] = useState<boolean>(isEdit);
  const [saving, setSaving] = useState(false);
  const [deleting, setDeleting] = useState(false);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [confirmDeleteOpen, setConfirmDeleteOpen] = useState(false);

  const fileInputRef = useRef<HTMLInputElement>(null);

  const backToDeck = useCallback(() => {
    if (deckId) {
      navigate(`/decks/${deckId}`);
    } else {
      navigate("/");
    }
  }, [deckId, navigate]);

  // Load the card + its images in edit mode.
  useEffect(() => {
    if (!cardId) {
      setForm(EMPTY_FORM);
      setImages([]);
      setLoading(false);
      return;
    }
    let cancelled = false;
    setLoading(true);
    setLoadError(null);
    (async () => {
      try {
        // Scope with `deleted_at = ""` so a trashed card reads as not-found:
        // the card `viewRule` has no soft-delete condition (ARCHITECTURE.md
        // §3.2), so a plain getOne would let a stale tab/bookmark/direct URL
        // open and edit a record that should only live in Trash.
        const [card, imgs] = await Promise.all([
          collections
            .cards()
            .getFirstListItem(`id = "${cardId}" && deleted_at = ""`),
          listCardImages(cardId),
        ]);
        if (cancelled) return;
        setForm(formFromCard(card));
        setImages(imgs);
      } catch (err) {
        if (cancelled) return;
        if (clearAuthOnUnauthorized(err)) return;
        setLoadError(
          err instanceof Error ? err.message : "Failed to load card.",
        );
      } finally {
        if (!cancelled) setLoading(false);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [cardId]);

  // Resolve token-carrying display URLs for the current images. `card_images`
  // files are protected, so URLs are minted async (see imageDisplayUrl).
  useEffect(() => {
    let cancelled = false;
    (async () => {
      const entries = await Promise.all(
        images.map(async (image): Promise<[string, string] | null> => {
          try {
            return [image.id, await imageDisplayUrl(image, { thumb: "300x300" })];
          } catch {
            return null;
          }
        }),
      );
      if (cancelled) return;
      setImageUrls(Object.fromEntries(entries.filter((e): e is [string, string] => e !== null)));
    })();
    return () => {
      cancelled = true;
    };
  }, [images]);

  // Re-mint a display URL for a single image whose <img> failed to load. The
  // most common cause on a long-lived editor session is an expired file token:
  // imageDisplayUrl embeds a short-lived `?token=` (FILE_TOKEN_TTL_MS) that the
  // resolve effect only mints once per `images` change, so a browser re-fetch
  // after expiry (lazy reveal, cache eviction, reconnect) 4xxs. Re-resolving
  // gets a fresh token. We guard against an infinite reload loop by only
  // updating state when the refreshed URL actually differs from the one we are
  // already showing (a new token changes the URL; an unchanged URL means a
  // genuine error, e.g. a 404, so re-rendering it would just loop).
  const handleImageError = useCallback(async (image: CardImage) => {
    try {
      const fresh = await imageDisplayUrl(image, { thumb: "300x300" });
      setImageUrls((prev) => {
        if (prev[image.id] === fresh) return prev;
        return { ...prev, [image.id]: fresh };
      });
    } catch {
      // Leave the broken image as-is; nothing more we can do here.
    }
  }, []);

  const onUploaded = useCallback((image: CardImage) => {
    setImages((prev) =>
      [...prev, image].sort((a, b) => a.position - b.position),
    );
  }, []);

  const { upload, pasteHandler, uploading, error: uploadError } =
    useImageUpload(cardId ?? "", onUploaded);

  const atImageLimit = images.length >= MAX_IMAGES_PER_CARD;
  const remainingSlots = Math.max(0, MAX_IMAGES_PER_CARD - images.length);

  const handleFilesSelected = useCallback(
    (fileList: FileList | null) => {
      if (!fileList || fileList.length === 0) return;
      const files = Array.from(fileList);
      if (files.length > remainingSlots) {
        toast({
          variant: "destructive",
          title: "Too many images",
          description: `A card can have at most ${MAX_IMAGES_PER_CARD} images. You can add ${remainingSlots} more.`,
        });
        return;
      }
      void upload(files);
    },
    [remainingSlots, upload],
  );

  const handleDeleteImage = useCallback(async (image: CardImage) => {
    try {
      await deleteCardImage(image.id);
      setImages((prev) => prev.filter((img) => img.id !== image.id));
    } catch (err) {
      if (clearAuthOnUnauthorized(err)) return;
      toast({
        variant: "destructive",
        title: "Could not remove image",
        description: err instanceof Error ? err.message : "Please try again.",
      });
    }
  }, []);

  const titleTrimmed = form.title.trim();
  const titleTooLong = form.title.length > TITLE_MAX;
  const canSave = titleTrimmed.length > 0 && !titleTooLong && !saving;

  const handleSave = useCallback(async () => {
    if (!deckId) return;
    if (titleTrimmed.length === 0 || titleTooLong) return;
    const fields: CardFields = {
      title: form.title.trim(),
      time_slot: form.time_slot,
      subjects: form.subjects,
      direction: form.direction,
      notes: form.notes,
    };
    setSaving(true);
    try {
      if (cardId) {
        await updateCard(cardId, fields);
        toast({ title: "Card saved" });
        backToDeck();
      } else {
        const created = await createCard(deckId, fields);
        toast({
          title: "Card created",
          description: "You can now add images to this card.",
        });
        // Transition into edit mode so images can be attached.
        navigate(`/decks/${deckId}/cards/${created.id}`, { replace: true });
      }
    } catch (err) {
      if (clearAuthOnUnauthorized(err)) return;
      toast({
        variant: "destructive",
        title: "Save failed",
        description: err instanceof Error ? err.message : "Please try again.",
      });
    } finally {
      setSaving(false);
    }
  }, [
    backToDeck,
    cardId,
    deckId,
    form,
    navigate,
    titleTooLong,
    titleTrimmed,
  ]);

  const handleDelete = useCallback(async () => {
    if (!cardId) return;
    setDeleting(true);
    try {
      await softDeleteCard(cardId);
      toast({ title: "Card deleted" });
      backToDeck();
    } catch (err) {
      setDeleting(false);
      setConfirmDeleteOpen(false);
      if (clearAuthOnUnauthorized(err)) return;
      toast({
        variant: "destructive",
        title: "Delete failed",
        description: err instanceof Error ? err.message : "Please try again.",
      });
    }
  }, [backToDeck, cardId]);

  const heading = isEdit ? "Edit card" : "New card";

  const titleCountClass = useMemo(
    () =>
      cn(
        "text-xs tabular-nums",
        titleTooLong ? "text-destructive" : "text-muted-foreground",
      ),
    [titleTooLong],
  );

  if (!deckId) {
    return (
      <div className="mx-auto max-w-2xl px-4 py-10">
        <p className="text-sm text-destructive">Missing deck.</p>
      </div>
    );
  }

  return (
    <div
      className="mx-auto max-w-2xl px-4 py-8"
      onPaste={isEdit ? pasteHandler : undefined}
    >
      <div className="mb-6 flex items-center justify-between gap-4">
        <h1 className="text-2xl font-semibold tracking-tight">{heading}</h1>
        <Button variant="ghost" size="sm" onClick={backToDeck}>
          <X className="h-4 w-4" />
          Close
        </Button>
      </div>

      {loading ? (
        <div className="flex items-center gap-2 py-16 text-muted-foreground">
          <Loader2 className="h-4 w-4 animate-spin" />
          Loading card…
        </div>
      ) : loadError ? (
        <div className="space-y-4 py-10">
          <p className="text-sm text-destructive">{loadError}</p>
          <Button variant="outline" onClick={backToDeck}>
            Back to deck
          </Button>
        </div>
      ) : (
        <form
          className="space-y-6"
          onSubmit={(e) => {
            e.preventDefault();
            void handleSave();
          }}
        >
          {/* Title (required) */}
          <div className="space-y-1.5">
            <div className="flex items-center justify-between">
              <Label htmlFor="card-title">
                Title <span className="text-destructive">*</span>
              </Label>
              <span className={titleCountClass}>
                {form.title.length}/{TITLE_MAX}
              </span>
            </div>
            <Input
              id="card-title"
              value={form.title}
              autoFocus
              placeholder="e.g. Bride & groom first look"
              aria-invalid={titleTooLong}
              onChange={(e) =>
                setForm((f) => ({ ...f, title: e.target.value }))
              }
            />
            {titleTooLong ? (
              <p className="text-xs text-destructive">
                Title must be {TITLE_MAX} characters or fewer.
              </p>
            ) : null}
          </div>

          {/* Time / slot */}
          <div className="space-y-1.5">
            <Label htmlFor="card-time">Time / slot</Label>
            <Input
              id="card-time"
              value={form.time_slot}
              placeholder='e.g. "16:30" or "during cocktails"'
              onChange={(e) =>
                setForm((f) => ({ ...f, time_slot: e.target.value }))
              }
            />
          </div>

          {/* Subjects / names */}
          <div className="space-y-1.5">
            <Label htmlFor="card-subjects">Subjects / names</Label>
            <Input
              id="card-subjects"
              value={form.subjects}
              placeholder="Who is in this shot?"
              onChange={(e) =>
                setForm((f) => ({ ...f, subjects: e.target.value }))
              }
            />
          </div>

          {/* Direction phrase */}
          <div className="space-y-1.5">
            <Label htmlFor="card-direction">Direction</Label>
            <Input
              id="card-direction"
              value={form.direction}
              placeholder="Short prompt to say aloud"
              onChange={(e) =>
                setForm((f) => ({ ...f, direction: e.target.value }))
              }
            />
          </div>

          {/* Notes */}
          <div className="space-y-1.5">
            <Label htmlFor="card-notes">Notes</Label>
            <Textarea
              id="card-notes"
              value={form.notes}
              rows={4}
              placeholder="Free-form notes"
              onChange={(e) =>
                setForm((f) => ({ ...f, notes: e.target.value }))
              }
            />
          </div>

          {/* Images */}
          <div className="space-y-3">
            <div className="flex items-center justify-between">
              <Label>
                Images{" "}
                <span className="font-normal text-muted-foreground">
                  ({images.length}/{MAX_IMAGES_PER_CARD})
                </span>
              </Label>
              {atImageLimit ? (
                <Badge variant="secondary">Max reached</Badge>
              ) : null}
            </div>

            {!isEdit ? (
              <p className="rounded-md border border-dashed px-3 py-6 text-center text-sm text-muted-foreground">
                Save the card first, then add up to {MAX_IMAGES_PER_CARD}{" "}
                images.
              </p>
            ) : (
              <>
                {images.length > 0 ? (
                  <ul className="grid grid-cols-3 gap-3 sm:grid-cols-4">
                    {images.map((image) => (
                      <li
                        key={image.id}
                        className="group relative aspect-square overflow-hidden rounded-md border bg-muted"
                      >
                        {imageUrls[image.id] ? (
                          <img
                            src={imageUrls[image.id]}
                            alt=""
                            className="h-full w-full object-cover"
                            loading="lazy"
                            onError={() => void handleImageError(image)}
                          />
                        ) : (
                          <div className="h-full w-full animate-pulse bg-muted" />
                        )}
                        <button
                          type="button"
                          aria-label="Remove image"
                          className="absolute right-1 top-1 rounded-full bg-background/80 p-1 text-foreground opacity-0 shadow transition-opacity hover:bg-background focus:opacity-100 group-hover:opacity-100"
                          onClick={() => void handleDeleteImage(image)}
                        >
                          <Trash2 className="h-4 w-4" />
                        </button>
                      </li>
                    ))}
                  </ul>
                ) : null}

                <div className="flex flex-wrap items-center gap-3">
                  <input
                    ref={fileInputRef}
                    type="file"
                    accept="image/*"
                    multiple
                    className="hidden"
                    onChange={(e) => {
                      handleFilesSelected(e.target.files);
                      // Allow re-selecting the same file.
                      e.target.value = "";
                    }}
                  />
                  <Button
                    type="button"
                    variant="outline"
                    disabled={atImageLimit || uploading}
                    onClick={() => fileInputRef.current?.click()}
                  >
                    {uploading ? (
                      <Loader2 className="h-4 w-4 animate-spin" />
                    ) : (
                      <ImagePlus className="h-4 w-4" />
                    )}
                    Add image
                  </Button>
                  <p className="text-xs text-muted-foreground">
                    or paste from clipboard
                    {atImageLimit
                      ? ""
                      : ` · ${remainingSlots} slot${remainingSlots === 1 ? "" : "s"} left`}
                  </p>
                </div>
                {uploadError ? (
                  <p className="text-xs text-destructive">{uploadError}</p>
                ) : null}
              </>
            )}
          </div>

          {/* Actions */}
          <div className="flex items-center justify-between gap-3 border-t pt-6">
            <div>
              {isEdit ? (
                <Button
                  type="button"
                  variant="destructive"
                  disabled={deleting}
                  onClick={() => setConfirmDeleteOpen(true)}
                >
                  <Trash2 className="h-4 w-4" />
                  Delete
                </Button>
              ) : null}
            </div>
            <div className="flex items-center gap-3">
              <Button type="button" variant="outline" onClick={backToDeck}>
                Cancel
              </Button>
              <Button type="submit" disabled={!canSave}>
                {saving ? <Loader2 className="h-4 w-4 animate-spin" /> : null}
                {isEdit ? "Save" : "Create card"}
              </Button>
            </div>
          </div>
        </form>
      )}

      <AlertDialog
        open={confirmDeleteOpen}
        onOpenChange={(open) => {
          if (!deleting) setConfirmDeleteOpen(open);
        }}
      >
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>Delete this card?</AlertDialogTitle>
            <AlertDialogDescription>
              The card will be moved out of the deck. This can be undone from
              the deck.
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel disabled={deleting}>Cancel</AlertDialogCancel>
            <AlertDialogAction
              className="bg-destructive text-destructive-foreground hover:bg-destructive/90"
              disabled={deleting}
              onClick={(e) => {
                e.preventDefault();
                void handleDelete();
              }}
            >
              {deleting ? (
                <Loader2 className="mr-2 h-4 w-4 animate-spin" />
              ) : null}
              Delete
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </div>
  );
}
