import { expect, test } from "@playwright/test";

import {
  OWNER_PASSWORD,
  addCard,
  createDeck,
  dateOffset,
  signIn,
  tinyPngBuffer,
  uniqueDeckName,
  waitForOutboxDrained,
} from "./helpers";

/**
 * M1 web prep MVP — core browser flows end-to-end against the live backend.
 *
 * Covers (per the milestone gate):
 *   login → create deck → see grouping → open deck → add/edit card →
 *   reorder → attach image.
 *
 * Runs serially (single worker) so mutations on the shared backend don't race.
 */

test.describe("M1 prep flow", () => {
  test("login authenticates and lands on the deck list", async ({ page }) => {
    await signIn(page);
    // Search box is a deck-list affordance; confirms we're on the home screen.
    await expect(
      page.getByPlaceholder("Search decks by name…"),
    ).toBeVisible();
  });

  test("rejects bad credentials with an inline error", async ({ page }) => {
    await page.goto("/login");
    await page.getByLabel("Email").fill("owner@posedeck.test");
    await page.getByLabel("Password").fill("definitely-wrong");
    await page.getByRole("button", { name: "Sign in" }).click();
    await expect(page.getByRole("alert")).toContainText(
      /invalid email or password/i,
    );
  });

  test("create deck navigates into the new deck detail", async ({ page }) => {
    await signIn(page);
    const name = await createDeck(page);
    // Deck detail shows a back link + an empty-state for a brand-new deck.
    await expect(page.getByRole("link", { name: /back to decks/i })).toBeVisible();
    await expect(page.getByText("No cards yet.")).toBeVisible();
    // URL is the deck detail route.
    await expect(page).toHaveURL(/\/decks\/[^/]+$/);
    expect(name).toBeTruthy();
  });

  test("deck list groups by date: Upcoming / Past", async ({ page }) => {
    await signIn(page);
    const upcomingName = uniqueDeckName("Upcoming");
    const pastName = uniqueDeckName("Past");

    // Create an upcoming deck (shoot date in the future) and a past one.
    await createDeck(page, { name: upcomingName, date: dateOffset(7) });
    await page.getByRole("link", { name: /back to decks/i }).click();
    await expect(
      page.getByRole("heading", { name: "Decks", level: 1 }),
    ).toBeVisible();

    await createDeck(page, { name: pastName, date: dateOffset(-7) });
    await page.getByRole("link", { name: /back to decks/i }).click();
    await expect(
      page.getByRole("heading", { name: "Decks", level: 1 }),
    ).toBeVisible();

    // Both section headers should be present (DESIGN.md §3.3 grouping).
    const upcomingSection = page
      .locator("section")
      .filter({ has: page.getByRole("heading", { name: "Upcoming" }) });
    const pastSection = page
      .locator("section")
      .filter({ has: page.getByRole("heading", { name: "Past" }) });

    await expect(upcomingSection).toBeVisible();
    await expect(pastSection).toBeVisible();

    // Each deck lands in the correct group.
    await expect(upcomingSection.getByText(upcomingName)).toBeVisible();
    await expect(pastSection.getByText(pastName)).toBeVisible();
  });

  test("search filters the deck list by name", async ({ page }) => {
    await signIn(page);
    const name = uniqueDeckName("Searchable");
    await createDeck(page, { name });
    await page.getByRole("link", { name: /back to decks/i }).click();
    await expect(
      page.getByRole("heading", { name: "Decks", level: 1 }),
    ).toBeVisible();

    const search = page.getByPlaceholder("Search decks by name…");
    await search.fill(name);
    await expect(page.getByText(name)).toBeVisible();

    await search.fill("zzz-no-such-deck-zzz");
    await expect(page.getByText(/No decks match/i)).toBeVisible();
  });

  test("add and edit a card from the deck detail", async ({ page }) => {
    await signIn(page);
    await createDeck(page);

    // Add card → opens the card editor in edit mode (new untitled card).
    await page.getByRole("button", { name: "Add card" }).click();
    await expect(
      page.getByRole("heading", { name: "Edit card" }),
    ).toBeVisible();

    // Editor loads the card async; wait until it seeds the title with the
    // server value before overwriting, so the load doesn't clobber our input.
    const titleField = page.getByRole("textbox", { name: /Title/ });
    await expect(titleField).toHaveValue("Untitled card");

    // Edit the structured fields (DESIGN.md §3.1).
    await titleField.fill("Golden hour portrait");
    await page.getByLabel("Time / slot").fill("07:30");
    await page.getByLabel("Subjects / names").fill("Model A");
    await page.getByLabel("Direction").fill("Backlit, soft squint");
    await page.getByLabel("Notes").fill("Bring a reflector.");

    await page.getByRole("button", { name: "Save" }).click();

    // Back on the deck detail (editor closes), the card row reflects the edits.
    await expect(
      page.getByRole("heading", { name: "Edit card" }),
    ).toBeHidden();
    const cardRow = page
      .locator("ul > li")
      .filter({ hasText: "Golden hour portrait" });
    await expect(cardRow).toHaveCount(1);
    await expect(cardRow).toContainText("Golden hour portrait");
    // Meta line shows time / subjects / direction joined together.
    await expect(cardRow).toContainText("07:30");
    await expect(cardRow).toContainText("Model A");
  });

  test("reorder cards via drag-and-drop persists across reload", async ({
    page,
  }) => {
    await signIn(page);
    await createDeck(page);

    // Create three cards with distinct titles.
    const titles = ["Card Alpha", "Card Bravo", "Card Charlie"];
    for (const title of titles) {
      await addCard(page, title);
    }

    const rows = page.locator("ul > li");
    await expect(rows).toHaveCount(3);

    // Initial order: Alpha, Bravo, Charlie.
    await expect(rows.nth(0)).toContainText("Card Alpha");
    await expect(rows.nth(2)).toContainText("Card Charlie");

    // Drag the first card's grip handle down past the third row. The handle is
    // now named per-card ("Reorder <card title>") after the M8 a11y pass.
    const firstHandle = rows
      .nth(0)
      .getByRole("button", { name: "Reorder Card Alpha" });
    const thirdRow = rows.nth(2);

    const handleBox = await firstHandle.boundingBox();
    const targetBox = await thirdRow.boundingBox();
    expect(handleBox).not.toBeNull();
    expect(targetBox).not.toBeNull();

    await page.mouse.move(
      handleBox!.x + handleBox!.width / 2,
      handleBox!.y + handleBox!.height / 2,
    );
    await page.mouse.down();
    // dnd-kit PointerSensor has a 4px activation distance; nudge then move.
    await page.mouse.move(
      handleBox!.x + handleBox!.width / 2,
      handleBox!.y + handleBox!.height / 2 + 10,
      { steps: 5 },
    );
    await page.mouse.move(
      targetBox!.x + targetBox!.width / 2,
      targetBox!.y + targetBox!.height + 20,
      { steps: 10 },
    );
    await page.mouse.up();

    // Alpha should no longer be first.
    await expect(page.locator("ul > li").nth(0)).not.toContainText(
      "Card Alpha",
    );

    // Capture the post-reorder order, then reload and confirm it persisted.
    const orderAfter = await page.locator("ul > li").allInnerTexts();
    // The reorder writes Dexie optimistically + enqueues outbox updates. Wait
    // for the queue to drain (mutations confirmed to the live backend) so the
    // post-reload hydrate sees the new positions, not a stale server snapshot.
    await waitForOutboxDrained(page);
    await page.reload();
    await expect(page.locator("ul > li")).toHaveCount(3);
    const orderReloaded = await page.locator("ul > li").allInnerTexts();

    const norm = (xs: string[]) =>
      xs.map((t) => t.replace(/\s+/g, " ").trim());
    expect(norm(orderReloaded)).toEqual(norm(orderAfter));
  });

  test("attach an image to a card via the file input", async ({ page }) => {
    await signIn(page);
    await createDeck(page);

    await page.getByRole("button", { name: "Add card" }).click();
    await expect(
      page.getByRole("heading", { name: "Edit card" }),
    ).toBeVisible();

    // The editor loads the card async (loading spinner first). Wait until the
    // image section is rendered in edit mode — the count badge starts at 0/5.
    await expect(page.getByText("(0/5)")).toBeVisible();

    // The file input is hidden; setInputFiles works regardless of visibility.
    const fileInput = page.locator('input[type="file"]');
    await fileInput.setInputFiles({
      name: "pose.png",
      mimeType: "image/png",
      buffer: tinyPngBuffer(),
    });

    // After compress + upload the count badge moves to 1/5 and a thumbnail
    // renders (the live backend stores the file; the app re-fetches a token URL).
    await expect(page.getByText("(1/5)")).toBeVisible({ timeout: 30_000 });
    await expect(page.locator("ul img").first()).toBeVisible({
      timeout: 30_000,
    });
  });
});

// Sanity: make sure the password constant is actually being exercised so a
// silent default doesn't mask a misconfigured env in CI.
test("seed password constant is non-empty", async () => {
  expect(OWNER_PASSWORD.length).toBeGreaterThan(0);
});
