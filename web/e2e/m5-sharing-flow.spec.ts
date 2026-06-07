import { expect, test } from "@playwright/test";

import {
  GUEST_EMAIL,
  createDeck,
  pollWithReload,
  signIn,
  signInAsGuest,
  waitForOutboxDrained,
} from "./helpers";

/**
 * E2E for M5 sharing.
 *
 * Drives the real app against the live dev backend (POSEDECK_DEV=true so the
 * seed `guest@posedeck.test` exists). Covers:
 *
 *  1. owner side (single context): sign in → create deck → Share → grant guest
 *     by email → see guest row → revoke → row disappears.
 *  2. cross-user (two contexts): owner grants the guest → guest sees the shared
 *     deck appear in their list and can open it read-only (no owner affordances)
 *     → owner revokes → the deck disappears from the guest's list and the open
 *     detail view shows "Deck not found.".
 *
 * The cross-user test uses two independent browser contexts (separate Dexie /
 * auth / IndexedDB) for the owner and the guest. Propagation to the guest is
 * asserted via `pollWithReload` (reload → re-hydrate from server) rather than
 * by waiting on the realtime socket, which is timing-flaky on a shared live
 * backend. The realtime *push* path (grant-resync / revoke-evict without a
 * reload) is covered deterministically by the realtimeManager unit tests
 * (FIX #1/#2/#7-web) and the live-PB integration suite.
 */

test("owner shares a deck by email and can revoke it", async ({ page }) => {
  await signIn(page);
  await createDeck(page, { name: `Share E2E ${Date.now()}` });
  await waitForOutboxDrained(page);

  // Open the deck options menu and choose Share.
  await page.getByRole("button", { name: "Deck options" }).click();
  await page.getByRole("menuitem", { name: "Share" }).click();

  const dialog = page.getByRole("dialog");
  await expect(dialog.getByText("Share deck")).toBeVisible();

  // Grant the seed guest by email.
  await dialog.getByLabel("Email").fill(GUEST_EMAIL);
  await dialog.getByRole("button", { name: "Share" }).click();

  // The guest row appears (we render the guest's user id) with a Revoke button.
  const revoke = dialog.getByRole("button", { name: "Revoke" });
  await expect(revoke).toBeVisible();
  await waitForOutboxDrained(page);

  // Revoke; the row disappears and the empty state returns.
  await revoke.click();
  await expect(dialog.getByText("Not shared with anyone yet.")).toBeVisible();
  await waitForOutboxDrained(page);
});

test("guest sees a shared deck appear, opens it read-only, loses it on revoke", async ({
  browser,
}) => {
  const deckName = `Shared E2E ${Date.now()}-${Math.floor(Math.random() * 10_000)}`;

  // Two independent contexts: separate auth + Dexie + IndexedDB per user.
  const ownerCtx = await browser.newContext();
  const guestCtx = await browser.newContext();
  const ownerPage = await ownerCtx.newPage();
  const guestPage = await guestCtx.newPage();

  try {
    // --- Owner: sign in, create the deck, grant the guest by email. ---
    await signIn(ownerPage);
    await createDeck(ownerPage, { name: deckName });
    await waitForOutboxDrained(ownerPage);

    await ownerPage.getByRole("button", { name: "Deck options" }).click();
    await ownerPage.getByRole("menuitem", { name: "Share" }).click();
    const shareDialog = ownerPage.getByRole("dialog");
    await expect(shareDialog.getByText("Share deck")).toBeVisible();
    await shareDialog.getByLabel("Email").fill(GUEST_EMAIL);
    await shareDialog.getByRole("button", { name: "Share" }).click();
    await expect(
      shareDialog.getByRole("button", { name: "Revoke" }),
    ).toBeVisible();
    await waitForOutboxDrained(ownerPage);

    // --- Guest: the shared deck appears in their list (post-hydrate). ---
    await signInAsGuest(guestPage);
    await pollWithReload(guestPage, () =>
      guestPage
        .getByText(deckName)
        .first()
        .isVisible()
        .catch(() => false),
    );

    // Open it: a guest views read-only — the owner-only Rename/Share/Delete
    // menu items are hidden (only the read-only menu, if any, is present).
    await guestPage.getByText(deckName).first().click();
    await expect(
      guestPage.getByRole("heading", { name: deckName, level: 1 }),
    ).toBeVisible();
    // The deck-options menu must not expose owner actions to a guest.
    const optionsBtn = guestPage.getByRole("button", { name: "Deck options" });
    if (await optionsBtn.isVisible().catch(() => false)) {
      await optionsBtn.click();
      await expect(
        guestPage.getByRole("menuitem", { name: "Share" }),
      ).toHaveCount(0);
      await expect(
        guestPage.getByRole("menuitem", { name: "Rename" }),
      ).toHaveCount(0);
      // Close the menu before continuing.
      await guestPage.keyboard.press("Escape");
    }
    // Capture the guest's deck-detail URL so we can revisit it post-revoke.
    const guestDeckUrl = guestPage.url();
    expect(guestDeckUrl).toMatch(/\/decks\/[^/]+$/);

    // --- Owner: revoke the grant. ---
    // The share dialog is still open from the grant above.
    await shareDialog.getByRole("button", { name: "Revoke" }).click();
    await expect(
      shareDialog.getByText("Not shared with anyone yet."),
    ).toBeVisible();
    await waitForOutboxDrained(ownerPage);

    // --- Guest: the deck disappears from the list (revoke-evict). ---
    await pollWithReload(guestPage, async () => {
      const stillThere = await guestPage
        .getByText(deckName)
        .first()
        .isVisible()
        .catch(() => false);
      return !stillThere;
    });

    // Opening the now-revoked deck detail directly shows "Deck not found.".
    await guestPage.goto(guestDeckUrl);
    await expect(guestPage.getByText("Deck not found.")).toBeVisible({
      timeout: 15_000,
    });
  } finally {
    await ownerCtx.close();
    await guestCtx.close();
  }
});
