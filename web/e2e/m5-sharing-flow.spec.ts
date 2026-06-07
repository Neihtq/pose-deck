import { expect, test } from "@playwright/test";

import { createDeck, signIn, waitForOutboxDrained } from "./helpers";

/**
 * E2E for M5 sharing (owner side).
 *
 * Drives the real app against the live dev backend (POSEDECK_DEV=true so the
 * seed `guest@posedeck.test` exists). Covers the owner-side share/revoke flow,
 * which is single-context and deterministic:
 *   sign in → create deck → Share → grant guest by email → see guest row →
 *   revoke → row disappears.
 *
 * The cross-user "guest sees the shared deck appear live in a SECOND context,
 * then it disappears on revoke" check is scaffolded but SKIPPED: it needs a
 * second authenticated browser context for the guest plus realtime-delivery
 * timing, which is flaky against a shared live backend. The realtime grant-
 * resync / revoke-evict behaviour it would exercise is covered deterministically
 * by the realtimeManager unit tests (FIX #1/#2/#7-web) and by the live-PB
 * integration suite (owner grant → guest reads deck → revoke → guest 404).
 */

const GUEST_EMAIL = process.env.E2E_GUEST_EMAIL ?? "guest@posedeck.test";

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

// SKIP (see file docstring): two-context guest-sees-it-live flow is flaky on a
// shared live backend; the underlying realtime behaviour is covered by unit +
// integration layers.
test.skip("guest sees a shared deck appear live, then disappear on revoke", async () => {
  // Scaffold:
  //  1. owner context: sign in, create deck, grant guest by email.
  //  2. guest context: sign in as guest@posedeck.test, assert the deck appears
  //     in the list (realtime grant-resync hydrates it).
  //  3. owner context: revoke.
  //  4. guest context: assert the deck disappears (revoke-evict) and an open
  //     deck-detail view shows "Deck not found.".
});
