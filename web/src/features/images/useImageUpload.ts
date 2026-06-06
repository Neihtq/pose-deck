/**
 * Image upload hook (ARCHITECTURE.md §5).
 *
 * Manages picking images from a file input and pasting them from the clipboard,
 * compresses each (1080px / JPEG q0.8) and uploads it to the given card. New
 * images are appended after the current highest position. Enforces the per-card
 * image limit; on overflow it surfaces a friendly `error` message.
 */
import { useCallback, useRef, useState } from "react";

import { compressImage, sha256Hex } from "./compress";
import {
  MAX_IMAGES_PER_CARD,
  TooManyImagesError,
  listCardImages,
  uploadCardImage,
} from "./imageApi";
import type { CardImage } from "@/lib/types";

/** Position gap used when appending images within a card. */
const POSITION_GAP = 1000;

/** Public shape of the {@link useImageUpload} hook. */
export interface UseImageUpload {
  /** Compress and upload the given image blobs (in order) to the card. */
  upload: (files: Iterable<Blob>) => Promise<CardImage[]>;
  /** Paste handler: extracts image blobs from a clipboard event and uploads them. */
  pasteHandler: (event: ClipboardEvent | React.ClipboardEvent) => void;
  /** True while a compress/upload batch is in flight. */
  uploading: boolean;
  /** Last error message, or null. */
  error: string | null;
}

/** Pull image blobs out of a clipboard event's items. */
export function imageBlobsFromClipboard(
  data: DataTransfer | null,
): Blob[] {
  if (!data) {
    return [];
  }
  const blobs: Blob[] = [];
  for (const item of Array.from(data.items)) {
    if (item.kind === "file" && item.type.startsWith("image/")) {
      const file = item.getAsFile();
      if (file) {
        blobs.push(file);
      }
    }
  }
  return blobs;
}

/**
 * Hook returning an `upload` callback, a `pasteHandler`, plus `uploading` and
 * `error` state for the given card.
 *
 * @param cardId    target card.
 * @param onUploaded optional callback invoked with each newly created record.
 */
export function useImageUpload(
  cardId: string,
  onUploaded?: (image: CardImage) => void,
): UseImageUpload {
  const [uploading, setUploading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  // Synchronous in-flight guard: prevents a concurrent paste + file-pick from
  // both passing the check-then-act image-count check and exceeding the cap.
  const inFlight = useRef(false);

  const upload = useCallback(
    async (files: Iterable<Blob>): Promise<CardImage[]> => {
      const blobs = Array.from(files).filter((f) => f.size > 0);
      if (blobs.length === 0) {
        return [];
      }
      if (inFlight.current) {
        setError("Please wait for the current upload to finish.");
        return [];
      }
      inFlight.current = true;

      setUploading(true);
      setError(null);
      const created: CardImage[] = [];
      try {
        // Determine the starting position from the current highest.
        const existing = await listCardImages(cardId);
        let nextPosition =
          existing.reduce((max, img) => Math.max(max, img.position), 0) +
          POSITION_GAP;

        if (existing.length + blobs.length > MAX_IMAGES_PER_CARD) {
          throw new TooManyImagesError(cardId);
        }

        // Dedup-on-upload (ARCHITECTURE.md §5 step 3): compute a SHA-256 of the
        // compressed bytes and skip blobs whose content matches one already
        // uploaded in this batch — e.g. the same image pasted and picked twice.
        const seenHashes = new Set<string>();
        for (const blob of blobs) {
          const compressed = await compressImage(blob);
          const hash = await sha256Hex(compressed);
          if (seenHashes.has(hash)) {
            continue;
          }
          seenHashes.add(hash);
          const image = await uploadCardImage(cardId, compressed, nextPosition);
          created.push(image);
          onUploaded?.(image);
          nextPosition += POSITION_GAP;
        }
        return created;
      } catch (err) {
        if (err instanceof TooManyImagesError) {
          setError(`A card can have at most ${MAX_IMAGES_PER_CARD} images.`);
        } else {
          setError(
            err instanceof Error ? err.message : "Failed to upload image.",
          );
        }
        return created;
      } finally {
        inFlight.current = false;
        setUploading(false);
      }
    },
    [cardId, onUploaded],
  );

  const pasteHandler = useCallback(
    (event: ClipboardEvent | React.ClipboardEvent) => {
      const clipboardData =
        "clipboardData" in event ? event.clipboardData : null;
      const blobs = imageBlobsFromClipboard(
        clipboardData as DataTransfer | null,
      );
      if (blobs.length > 0) {
        event.preventDefault();
        void upload(blobs);
      }
    },
    [upload],
  );

  return { upload, pasteHandler, uploading, error };
}
