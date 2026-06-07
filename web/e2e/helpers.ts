import { expect, type Page } from "@playwright/test";

/**
 * Shared E2E helpers + constants for the Pose Deck web app.
 *
 * Credentials come from the dev seed migration
 * (backend/pb_migrations/1700000010_dev_seed.js). They only exist when the
 * backend is started with POSEDECK_DEV=true.
 */
export const OWNER_EMAIL = process.env.E2E_EMAIL ?? "owner@posedeck.test";
export const OWNER_PASSWORD = process.env.E2E_PASSWORD ?? "changeme123";

/** Generate a unique deck name so parallel/repeat runs never collide. */
export function uniqueDeckName(prefix = "E2E Deck"): string {
  return `${prefix} ${Date.now()}-${Math.floor(Math.random() * 10_000)}`;
}

/**
 * Sign in via the real /login form and wait until the deck list ("Decks")
 * is shown. Asserts on the way so a backend/auth misconfiguration fails loud.
 */
export async function signIn(page: Page): Promise<void> {
  await page.goto("/login");
  await page.getByLabel("Email").fill(OWNER_EMAIL);
  await page.getByLabel("Password").fill(OWNER_PASSWORD);
  await page.getByRole("button", { name: "Sign in" }).click();

  // RequireAuth redirects to "/" → DeckListPage renders an <h1>Decks</h1>.
  await expect(
    page.getByRole("heading", { name: "Decks", level: 1 }),
  ).toBeVisible();
}

/**
 * Create a deck from the deck list via the "New deck" dialog. Optionally sets
 * a shoot date (YYYY-MM-DD). On success the app navigates into the deck detail
 * page; resolves once the deck heading is visible. Returns the deck name.
 */
export async function createDeck(
  page: Page,
  opts: { name?: string; date?: string } = {},
): Promise<string> {
  const name = opts.name ?? uniqueDeckName();
  // Open the create dialog (header button).
  await page.getByRole("button", { name: "New deck" }).first().click();

  const dialog = page.getByRole("dialog");
  await expect(dialog.getByText("New deck")).toBeVisible();
  await dialog.getByLabel("Name").fill(name);
  if (opts.date) {
    await dialog.getByLabel("Shoot date (optional)").fill(opts.date);
  }
  await dialog.getByRole("button", { name: "Create deck" }).click();

  // Navigates to /decks/:id; deck detail renders the name as an <h1>.
  await expect(
    page.getByRole("heading", { name, level: 1 }),
  ).toBeVisible();
  return name;
}

/**
 * Add a card to the open deck detail and save it with the given title.
 *
 * Robust against the deck-detail re-render churn: the "Add card" button
 * briefly relabels to "Adding…" while the create is in flight and the card
 * list re-renders after each save, which can detach the button mid-click. We
 * wait for the button to be enabled before clicking, wait for the editor to
 * seed the async-loaded title before overwriting it (so the load doesn't
 * clobber our input), then confirm the saved row appears in the list before
 * returning so the caller can safely add the next card.
 */
export async function addCard(page: Page, title: string): Promise<void> {
  const addButton = page.getByRole("button", { name: /^Add card$/ });
  await expect(addButton).toBeEnabled();
  await addButton.click();

  await expect(page.getByRole("heading", { name: "Edit card" })).toBeVisible();
  const field = page.getByRole("textbox", { name: /Title/ });
  // The editor loads the card async; wait for it to seed the title with the
  // server value before overwriting so the load doesn't clobber our input.
  await expect(field).toHaveValue("Untitled card");
  await field.fill(title);
  await page.getByRole("button", { name: "Save" }).click();

  // Back on the deck detail: confirm the saved row rendered before continuing.
  await expect(page.getByRole("heading", { name: "Edit card" })).toBeHidden();
  await expect(
    page.locator("ul > li").filter({ hasText: title }),
  ).toHaveCount(1);
}

/**
 * Wait until the Dexie outbox queue is empty — i.e. every queued mutation has
 * been confirmed to the live backend. Reads the `outbox` table directly via the
 * raw IndexedDB API in the page context (DB name `pose-deck`, see lib/db.ts).
 *
 * The app is local-first: a mutation writes Dexie optimistically and enqueues
 * an outbox entry that the sync engine drains to PocketBase. Reloading before
 * the queue drains races the post-reload `hydrateFromServer`, which can read a
 * server snapshot that predates the un-flushed mutation. Awaiting an empty
 * outbox makes "persisted across reload" deterministic.
 */
export async function waitForOutboxDrained(page: Page): Promise<void> {
  await expect
    .poll(
      async () =>
        page.evaluate(
          () =>
            new Promise<number>((resolve, reject) => {
              const open = indexedDB.open("pose-deck");
              open.onerror = () => reject(open.error);
              open.onsuccess = () => {
                const dbConn = open.result;
                if (!dbConn.objectStoreNames.contains("outbox")) {
                  dbConn.close();
                  resolve(0);
                  return;
                }
                const tx = dbConn.transaction("outbox", "readonly");
                const countReq = tx.objectStore("outbox").count();
                countReq.onerror = () => {
                  dbConn.close();
                  reject(countReq.error);
                };
                countReq.onsuccess = () => {
                  dbConn.close();
                  resolve(countReq.result);
                };
              };
            }),
        ),
      { timeout: 30_000, intervals: [100, 250, 500] },
    )
    .toBe(0);
}

/** A YYYY-MM-DD string offset from today by `days` (local time). */
export function dateOffset(days: number): string {
  const d = new Date();
  d.setDate(d.getDate() + days);
  const y = d.getFullYear();
  const m = String(d.getMonth() + 1).padStart(2, "0");
  const day = String(d.getDate()).padStart(2, "0");
  return `${y}-${m}-${day}`;
}

/**
 * A small valid 8x8 RGB PNG as a Buffer, for image-upload tests. Must be a
 * fully decodable image: the upload pipeline runs `createImageBitmap` +
 * canvas re-encode (see features/images/compress.ts), which rejects malformed
 * or zero-area inputs with "source image could not be decoded".
 */
export function tinyPngBuffer(): Buffer {
  const base64 =
    "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAEUlEQVR4nGM4kWKEFTEMLQkAVkZXgTy9n4kAAAAASUVORK5CYII=";
  return Buffer.from(base64, "base64");
}
