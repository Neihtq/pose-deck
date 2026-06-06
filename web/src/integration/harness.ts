/**
 * Shared helpers for the integration suite: authenticated clients against the
 * live server, plus idempotent record creation + cleanup tracking.
 *
 * Each test creates its own records and tears them down (decks; cards/images/
 * guests/completions cascade-delete with their parent, but we also track and
 * best-effort delete leaf records to keep the seeded DB pristine across runs).
 */
import PocketBase from "pocketbase";

import {
  GUEST_EMAIL,
  OWNER_EMAIL,
  SEED_PASSWORD,
} from "./pbServer";

/** A fresh, unauthenticated client pointed at the live server. */
export function makeClient(url: string): PocketBase {
  return new PocketBase(url);
}

/** Authenticate a fresh client as the dev-seed owner. */
export async function authOwner(url: string): Promise<PocketBase> {
  const pb = makeClient(url);
  await pb
    .collection("users")
    .authWithPassword(OWNER_EMAIL, SEED_PASSWORD);
  return pb;
}

/** Authenticate a fresh client as the dev-seed guest. */
export async function authGuest(url: string): Promise<PocketBase> {
  const pb = makeClient(url);
  await pb
    .collection("users")
    .authWithPassword(GUEST_EMAIL, SEED_PASSWORD);
  return pb;
}

/** ISO 8601 now, matching the data layer's `client_updated_at` stamping. */
export function nowIso(): string {
  return new Date().toISOString();
}

/**
 * Bytes of a valid 1x1 PNG. `card_images.file` enforces a real
 * `image/png` mime type (PocketBase sniffs content), so a truncated
 * signature is rejected — this is a genuine, decodable PNG.
 */
const PNG_1X1: number[] = [
  137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0,
  0, 0, 1, 8, 2, 0, 0, 0, 144, 119, 83, 222, 0, 0, 0, 12, 73, 68, 65, 84, 120,
  156, 99, 248, 207, 192, 0, 0, 3, 1, 1, 0, 201, 254, 146, 239, 0, 0, 0, 0, 73,
  69, 78, 68, 174, 66, 96, 130,
];

/** Create a `card_images` record with a valid PNG, tracked for cleanup. */
export async function createImage(
  pb: PocketBase,
  cleanup: Cleanup,
  cardId: string,
  position = 1000,
): Promise<{ id: string } & Record<string, unknown>> {
  const form = new FormData();
  form.append("card", cardId);
  form.append("position", String(position));
  form.append(
    "file",
    new Blob([Uint8Array.from(PNG_1X1)], { type: "image/png" }),
    "pixel.png",
  );
  const rec = await pb.collection("card_images").create(form);
  cleanup.track(pb, "card_images", rec.id);
  return rec as { id: string } & Record<string, unknown>;
}

/**
 * Tracks created records so a test can clean them up in reverse order.
 * Deletion failures are swallowed (a parent delete may have already
 * cascade-removed a child).
 */
export class Cleanup {
  private items: Array<{ pb: PocketBase; collection: string; id: string }> = [];

  track(pb: PocketBase, collection: string, id: string): void {
    this.items.push({ pb, collection, id });
  }

  async run(): Promise<void> {
    for (const { pb, collection, id } of this.items.reverse()) {
      try {
        await pb.collection(collection).delete(id);
      } catch {
        /* already gone (cascade) or not permitted — ignore */
      }
    }
    this.items = [];
  }
}

/** Create a deck owned by the authed user, tracked for cleanup. */
export async function createDeck(
  pb: PocketBase,
  cleanup: Cleanup,
  fields: { name: string; shoot_date?: string; deleted_at?: string },
): Promise<{ id: string } & Record<string, unknown>> {
  const ownerId = pb.authStore.record?.id as string;
  const rec = await pb.collection("decks").create({
    owner: ownerId,
    name: fields.name,
    shoot_date: fields.shoot_date ?? "",
    deleted_at: fields.deleted_at ?? "",
    client_updated_at: nowIso(),
  });
  cleanup.track(pb, "decks", rec.id);
  return rec as { id: string } & Record<string, unknown>;
}

/** Create a card in a deck, tracked for cleanup. */
export async function createCard(
  pb: PocketBase,
  cleanup: Cleanup,
  deckId: string,
  fields: { title: string; position?: number; deleted_at?: string },
): Promise<{ id: string } & Record<string, unknown>> {
  const rec = await pb.collection("cards").create({
    deck: deckId,
    title: fields.title,
    position: fields.position ?? 1000,
    deleted_at: fields.deleted_at ?? "",
    client_updated_at: nowIso(),
  });
  cleanup.track(pb, "cards", rec.id);
  return rec as { id: string } & Record<string, unknown>;
}

/** Assert a PocketBase request fails with the expected HTTP status. */
export async function expectStatus(
  promise: Promise<unknown>,
  status: number,
): Promise<void> {
  try {
    await promise;
  } catch (err) {
    const got = (err as { status?: number }).status;
    if (got !== status) {
      throw new Error(`expected status ${status}, got ${got}: ${String(err)}`);
    }
    return;
  }
  throw new Error(`expected request to fail with status ${status}, but it succeeded`);
}
