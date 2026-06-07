/**
 * INTEGRATION: server contracts the M5 SHARING layer relies on.
 *
 * Runs against a LIVE PocketBase (ephemeral, started by globalSetup) with the
 * version-controlled migrations + dev seed applied.
 *
 * The M1 contract test already pins basic `deck_guests` create/list/revoke and
 * the relaxed `users` email lookup; the M3 sync test pins guest-write drop-class
 * 4xx and no-grant realtime scoping. This file pins the REMAINING server
 * behaviour the M5 sharing data layer (`guestApi.ts` + ShareDeckDialog flow,
 * ARCHITECTURE.md §3.5 / §6) ASSUMES but that is not yet covered — the ones
 * that, if the server diverged, would silently break the share flow:
 *
 *  - EXACT-EMAIL RESOLUTION (resolveUserByEmail): the `email` query param is an
 *    EXACT, case-sensitive match. A differently-cased or padded email resolves
 *    to nobody, and the caller's own email never resolves to a user id (the
 *    caller row is filtered out). This pins guestApi's "resolve by exact email,
 *    or null" contract — a case-insensitive server match could grant the wrong
 *    account.
 *  - REVOKE FULLY REVOKES (§6 step 5): after the owner deletes the grant, the
 *    guest not only loses deck/card READ but can no longer CREATE a
 *    card_completion for that deck's cards (the completion createRule re-checks
 *    deck access). The engine relies on this 4xx being drop-class.
 *  - COMPLETION SURVIVES REVOKE: a completion the guest already wrote stays
 *    readable to that guest after revoke, because card_completions.viewRule is
 *    `user = @request.auth.id` — independent of deck access. (If revoke cascaded
 *    completions away, the guest's local progress would desync on rehydrate.)
 *  - GRANT IS OWNER-ONLY & NON-TRANSITIVE: a granted guest cannot grant the deck
 *    onward (createRule `deck.owner = auth.id`) and cannot UPDATE an existing
 *    grant (updateRule, untested elsewhere). Sharing fans out from the owner only.
 *  - REALTIME GRANT PROPAGATION (§6 step 4, realtimeManager): once the owner
 *    grants access, a subsequent deck UPDATE is delivered over live SSE to the
 *    guest's rule-scoped `decks` subscription — this is what makes a shared deck
 *    "appear / update" on the friend's device without a manual refresh.
 *  - GUEST SEES THE GRANT ROW; OWNER REVOKE IS A REAL HARD DELETE that the guest
 *    observes (the deck_guests row 404s for both afterwards).
 *
 * Idempotent: every created record is tracked and cleaned up; children cascade
 * with their parent. The seeded DB is left as found.
 */
import PocketBase from "pocketbase";
import { afterEach, beforeAll, describe, expect, inject, it } from "vitest";

import {
  authGuest,
  authOwner,
  Cleanup,
  createCard,
  createDeck,
  nowIso,
} from "./harness";
import { GUEST_EMAIL, OWNER_EMAIL } from "./pbServer";

const pbUrl = inject("pbUrl");
const pbSkipReason = inject("pbSkipReason");

const d = pbUrl ? describe : describe.skip;
if (!pbUrl) {
  // eslint-disable-next-line no-console
  console.warn(`[integration:sharing] SKIPPED: ${pbSkipReason}`);
}

/** Wait until `cond()` is true or the timeout lapses (realtime delivery). */
async function waitFor(
  cond: () => boolean,
  { timeoutMs = 5000, stepMs = 50 }: { timeoutMs?: number; stepMs?: number } = {},
): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (cond()) return;
    await new Promise((r) => setTimeout(r, stepMs));
  }
  if (!cond()) throw new Error(`waitFor: condition not met within ${timeoutMs}ms`);
}

/**
 * Mirror of `guestApi.resolveUserByEmail`: pass ONLY the email query param and
 * pick the row whose id is not the caller's. This is the exact production query.
 */
async function resolveUserByEmail(
  pb: PocketBase,
  callerId: string,
  email: string,
): Promise<string | null> {
  const rows = await pb.collection("users").getFullList({ query: { email } });
  return rows.find((r) => r.id !== callerId)?.id ?? null;
}

async function expectStatusErr(
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

d("M5 sharing server contracts", () => {
  let owner: PocketBase;
  let guest: PocketBase;
  let ownerId: string;
  let guestId: string;
  const cleanup = new Cleanup();

  beforeAll(async () => {
    owner = await authOwner(pbUrl);
    guest = await authGuest(pbUrl);
    ownerId = owner.authStore.record?.id as string;
    guestId = guest.authStore.record?.id as string;
  });

  afterEach(async () => {
    await cleanup.run();
  });

  // ---- exact-email resolution (resolveUserByEmail) ------------------------

  describe("resolveUserByEmail is an EXACT, case-sensitive match", () => {
    it("resolves the guest's id for the exact email", async () => {
      expect(await resolveUserByEmail(owner, ownerId, GUEST_EMAIL)).toBe(guestId);
    });

    it("a differently-cased email resolves to null (no fuzzy/ci match)", async () => {
      // If PocketBase matched case-insensitively, share-by-email could resolve a
      // user the owner did not intend. Pin the exact-match contract guestApi assumes.
      expect(
        await resolveUserByEmail(owner, ownerId, GUEST_EMAIL.toUpperCase()),
      ).toBeNull();
    });

    it("a padded email (trailing space) resolves to null (no trimming server-side)", async () => {
      expect(
        await resolveUserByEmail(owner, ownerId, `${GUEST_EMAIL} `),
      ).toBeNull();
    });

    it("resolving the CALLER's own email yields null (caller row is filtered out)", async () => {
      // guestApi picks the row whose id != caller; the owner querying their own
      // email gets only their own row back → resolves to null, never self-shares.
      expect(await resolveUserByEmail(owner, ownerId, OWNER_EMAIL)).toBeNull();
    });

    it("a non-existent email resolves to null", async () => {
      expect(
        await resolveUserByEmail(owner, ownerId, "nobody-m5@nowhere.test"),
      ).toBeNull();
    });
  });

  // ---- revoke fully revokes (deck + future completions) -------------------

  describe("revoke fully revokes deck access (read + future completions)", () => {
    it("after revoke the guest loses deck/card read AND cannot create a new completion", async () => {
      const deck = await createDeck(owner, cleanup, { name: "Revoke deck" });
      const card = await createCard(owner, cleanup, deck.id, {
        title: "Revoke card",
        position: 1000,
      });
      const grant = await owner.collection("deck_guests").create({
        deck: deck.id,
        user: guestId,
        granted_at: nowIso(),
      });
      cleanup.track(owner, "deck_guests", grant.id);

      // While granted the guest can read the card and write a completion.
      expect((await guest.collection("cards").getOne(card.id)).id).toBe(card.id);
      const comp = await guest.collection("card_completions").create({
        card: card.id,
        user: guestId,
        state: "done",
        changed_at: nowIso(),
      });
      cleanup.track(guest, "card_completions", comp.id);

      // Owner revokes (real hard delete).
      await owner.collection("deck_guests").delete(grant.id);

      // Deck + card read gone.
      await expectStatusErr(guest.collection("decks").getOne(deck.id), 404);
      await expectStatusErr(guest.collection("cards").getOne(card.id), 404);

      // A NEW completion for that deck's card is rejected (createRule re-checks
      // deck access). This must be a drop-class 4xx so the sync engine drops it.
      await expectStatusErr(
        guest.collection("card_completions").create({
          card: card.id,
          user: guestId,
          state: "skipped",
          changed_at: nowIso(),
        }),
        400,
      );
    });

    it("a completion the guest already wrote SURVIVES revoke (viewRule is user-scoped, not deck-scoped)", async () => {
      const deck = await createDeck(owner, cleanup, { name: "Survive deck" });
      const card = await createCard(owner, cleanup, deck.id, {
        title: "Survive card",
        position: 1000,
      });
      const grant = await owner.collection("deck_guests").create({
        deck: deck.id,
        user: guestId,
        granted_at: nowIso(),
      });
      cleanup.track(owner, "deck_guests", grant.id);

      const comp = await guest.collection("card_completions").create({
        card: card.id,
        user: guestId,
        state: "done",
        changed_at: nowIso(),
      });
      cleanup.track(guest, "card_completions", comp.id);

      await owner.collection("deck_guests").delete(grant.id);

      // card_completions.viewRule = `user = @request.auth.id`, independent of
      // deck access — so the guest's own prior progress row is still readable.
      expect(
        (await guest.collection("card_completions").getOne(comp.id)).id,
      ).toBe(comp.id);
    });
  });

  // ---- grant is owner-only & non-transitive -------------------------------

  describe("granting fans out from the owner only", () => {
    it("a granted guest cannot grant the deck onward, nor update an existing grant", async () => {
      const deck = await createDeck(owner, cleanup, { name: "Non-transitive deck" });
      const grant = await owner.collection("deck_guests").create({
        deck: deck.id,
        user: guestId,
        granted_at: nowIso(),
      });
      cleanup.track(owner, "deck_guests", grant.id);

      // Guest (now with read access) cannot create another grant for the deck —
      // createRule is `deck.owner = @request.auth.id`. PocketBase surfaces a
      // failed create-rule on a base collection as 400.
      await expectStatusErr(
        guest.collection("deck_guests").create({
          deck: deck.id,
          user: guestId,
          granted_at: nowIso(),
        }),
        400,
      );

      // Guest cannot UPDATE the existing grant either (updateRule owner-only;
      // a denied update on a visible-but-unwritable record reads back as 404).
      await expectStatusErr(
        guest.collection("deck_guests").update(grant.id, { granted_at: nowIso() }),
        404,
      );
    });
  });

  // ---- realtime grant propagation (§6 step 4) -----------------------------

  describe("realtime delivers shared-deck updates to the guest after a grant", () => {
    it("guest's decks subscription receives a deck UPDATE once granted (not before)", async () => {
      const events: Array<{ action: string; id: string }> = [];
      const unsub = await guest.collection("decks").subscribe("*", (e) => {
        events.push({ action: e.action, id: e.record.id });
      });

      try {
        // Owner creates a private deck — guest is NOT granted yet, so no event.
        const deck = await createDeck(owner, cleanup, { name: "RT share deck" });
        await new Promise((r) => setTimeout(r, 1200));
        expect(events.some((e) => e.id === deck.id)).toBe(false);

        // Owner grants the guest access.
        const grant = await owner.collection("deck_guests").create({
          deck: deck.id,
          user: guestId,
          granted_at: nowIso(),
        });
        cleanup.track(owner, "deck_guests", grant.id);

        // Now a deck update must reach the guest's rule-scoped subscription —
        // this is what makes a shared deck stay live on the friend's device.
        await owner.collection("decks").update(deck.id, {
          name: "RT share deck v2",
          client_updated_at: nowIso(),
        });
        await waitFor(() =>
          events.some((e) => e.action === "update" && e.id === deck.id),
        );
      } finally {
        await unsub();
      }
    });
  });

  // ---- grant row visibility + observable revoke ---------------------------

  describe("grant row visibility and observable revoke", () => {
    it("both owner and guest see the grant row; after revoke it 404s for both", async () => {
      const deck = await createDeck(owner, cleanup, { name: "Grant row deck" });
      const grant = await owner.collection("deck_guests").create({
        deck: deck.id,
        user: guestId,
        granted_at: nowIso(),
      });

      expect((await owner.collection("deck_guests").getOne(grant.id)).id).toBe(
        grant.id,
      );
      expect((await guest.collection("deck_guests").getOne(grant.id)).id).toBe(
        grant.id,
      );

      await owner.collection("deck_guests").delete(grant.id);

      await expectStatusErr(owner.collection("deck_guests").getOne(grant.id), 404);
      await expectStatusErr(guest.collection("deck_guests").getOne(grant.id), 404);
    });
  });
});
