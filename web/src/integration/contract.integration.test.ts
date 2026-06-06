/**
 * INTEGRATION: server contract the M1 web data layer relies on.
 *
 * Runs against a LIVE PocketBase (ephemeral, started by globalSetup) with the
 * version-controlled migrations + dev seed applied. Asserts the actual server
 * behaviour that `deckApi.ts` / `cardApi.ts` / `pocketbase.ts` assume:
 *
 *  - API rules: owner vs guest visibility across every collection
 *    (decks, cards, card_images, deck_guests, card_completions).
 *  - Soft-delete filtering (the `deleted_at = ""` query contract).
 *  - Cascade deletes (deck → cards → card_images; deck_guests; completions).
 *  - Required-field validation (deck.name/owner, card.title/deck,
 *    card_completions.state enum + composite-unique).
 *  - Reorder/position behaviour (integer-gap restripe).
 *
 * Idempotent: every created record is tracked and cleaned up; children
 * cascade with their parent. The seed DB is left as found.
 */
import PocketBase from "pocketbase";
import { beforeAll, afterEach, describe, expect, it, inject } from "vitest";

import {
  authGuest,
  authOwner,
  Cleanup,
  createCard,
  createDeck,
  createImage,
  expectStatus,
  makeClient,
  nowIso,
} from "./harness";
import { OWNER_EMAIL, SEED_PASSWORD } from "./pbServer";

const pbUrl = inject("pbUrl");
const pbSkipReason = inject("pbSkipReason");

// If globalSetup couldn't obtain a backend, skip the whole suite with the
// reason surfaced in the report rather than failing.
const d = pbUrl ? describe : describe.skip;
if (!pbUrl) {
  // eslint-disable-next-line no-console
  console.warn(`[integration] SKIPPED: ${pbSkipReason}`);
}

d("PocketBase contract", () => {
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

  // ---- auth ---------------------------------------------------------------

  describe("auth", () => {
    it("seeded owner + guest authenticate with email/password", () => {
      expect(owner.authStore.isValid).toBe(true);
      expect(guest.authStore.isValid).toBe(true);
      expect(ownerId).toBeTruthy();
      expect(guestId).toBeTruthy();
      expect(ownerId).not.toBe(guestId);
    });

    it("rejects bad credentials and public signup is disabled", async () => {
      const anon = makeClient(pbUrl);
      await expectStatus(
        anon.collection("users").authWithPassword(OWNER_EMAIL, "wrong-pass"),
        400,
      );
      // users.createRule = null → no public signup. PocketBase surfaces a
      // null create rule as 403 ("Only superusers can perform this action").
      await expectStatus(
        anon.collection("users").create({
          email: "intruder@posedeck.test",
          password: SEED_PASSWORD,
          passwordConfirm: SEED_PASSWORD,
          name: "Intruder",
        }),
        403,
      );
    });

    it("a user can view only their own users record", async () => {
      // owner can read self...
      const self = await owner.collection("users").getOne(ownerId);
      expect(self.id).toBe(ownerId);
      // ...but not the guest's record (viewRule: id = @request.auth.id).
      await expectStatus(owner.collection("users").getOne(guestId), 404);
    });
  });

  // ---- owner vs guest visibility -----------------------------------------

  describe("decks visibility (API rules)", () => {
    it("owner sees own deck; guest cannot until granted, then can (read-only)", async () => {
      const deck = await createDeck(owner, cleanup, { name: "Visibility deck" });

      // Owner can view + list.
      const viewed = await owner.collection("decks").getOne(deck.id);
      expect(viewed.id).toBe(deck.id);

      // Guest cannot view/list before a grant.
      await expectStatus(guest.collection("decks").getOne(deck.id), 404);
      const guestBefore = await guest
        .collection("decks")
        .getFullList({ filter: `id = "${deck.id}"` });
      expect(guestBefore).toHaveLength(0);

      // Owner grants guest access.
      const grant = await owner.collection("deck_guests").create({
        deck: deck.id,
        user: guestId,
        granted_at: nowIso(),
      });
      cleanup.track(owner, "deck_guests", grant.id);

      // Now the guest can view + list the deck.
      const guestViewed = await guest.collection("decks").getOne(deck.id);
      expect(guestViewed.id).toBe(deck.id);
      const guestAfter = await guest
        .collection("decks")
        .getFullList({ filter: `id = "${deck.id}"` });
      expect(guestAfter.map((d) => d.id)).toContain(deck.id);

      // But the guest is READ-ONLY: cannot update or delete the deck.
      await expectStatus(
        guest.collection("decks").update(deck.id, { name: "hijacked" }),
        404,
      );
      await expectStatus(guest.collection("decks").delete(deck.id), 404);
    });

    it("createRule honors the client-set owner (why deckApi stamps the auth user)", async () => {
      // The deck createRule is `@request.auth.id != ""` with no constraint
      // tying `owner` to the creator, so the SERVER does not auto-populate or
      // validate owner. The client is responsible for setting it — which is
      // exactly what deckApi.createDeck does via currentUserId(). This test
      // pins that contract: a create succeeds and persists whatever owner the
      // client sent, verbatim.
      const created = await guest.collection("decks").create({
        owner: guestId,
        name: "Guest-owned deck",
        shoot_date: "",
        deleted_at: "",
        client_updated_at: nowIso(),
      });
      cleanup.track(guest, "decks", created.id);
      expect(created.owner).toBe(guestId);

      // And the owner (a different user) cannot see the guest's deck —
      // confirming owner-scoped visibility still applies to the new record.
      await expectStatus(owner.collection("decks").getOne(created.id), 404);
    });
  });

  describe("cards & card_images inherit deck visibility", () => {
    it("guest reads cards + images only after a deck grant", async () => {
      const deck = await createDeck(owner, cleanup, { name: "Card vis deck" });
      const card = await createCard(owner, cleanup, deck.id, {
        title: "Inherited card",
        position: 1000,
      });

      // Attach an image so card_images visibility can be checked too.
      const image = await createImage(owner, cleanup, card.id);

      // Guest sees neither before a grant.
      await expectStatus(guest.collection("cards").getOne(card.id), 404);
      await expectStatus(
        guest.collection("card_images").getOne(image.id),
        404,
      );

      const grant = await owner.collection("deck_guests").create({
        deck: deck.id,
        user: guestId,
        granted_at: nowIso(),
      });
      cleanup.track(owner, "deck_guests", grant.id);

      // After the grant both inherit visibility through the deck relation.
      expect((await guest.collection("cards").getOne(card.id)).id).toBe(card.id);
      expect((await guest.collection("card_images").getOne(image.id)).id).toBe(
        image.id,
      );

      // Read-only: guest cannot create/edit cards in the deck.
      await expectStatus(
        guest.collection("cards").create({
          deck: deck.id,
          title: "guest card",
          position: 2000,
          deleted_at: "",
          client_updated_at: nowIso(),
        }),
        400,
      );
      await expectStatus(
        guest.collection("cards").update(card.id, { title: "edited" }),
        404,
      );
    });
  });

  describe("deck_guests visibility", () => {
    it("owner and the granted guest can list the grant; only owner can revoke", async () => {
      const deck = await createDeck(owner, cleanup, { name: "Guest grant deck" });
      const grant = await owner.collection("deck_guests").create({
        deck: deck.id,
        user: guestId,
        granted_at: nowIso(),
      });
      cleanup.track(owner, "deck_guests", grant.id);

      // Owner sees the grant.
      expect(
        (await owner.collection("deck_guests").getOne(grant.id)).id,
      ).toBe(grant.id);
      // The guest themselves sees it (listRule: ... || user = auth.id).
      expect(
        (await guest.collection("deck_guests").getOne(grant.id)).id,
      ).toBe(grant.id);

      // Guest cannot create a grant (only deck owner may).
      await expectStatus(
        guest.collection("deck_guests").create({
          deck: deck.id,
          user: guestId,
          granted_at: nowIso(),
        }),
        400,
      );
      // Guest cannot revoke.
      await expectStatus(
        guest.collection("deck_guests").delete(grant.id),
        404,
      );
    });
  });

  describe("card_completions visibility (per-user, private)", () => {
    it("each user sees only their own completion; states are not shared", async () => {
      const deck = await createDeck(owner, cleanup, { name: "Completion deck" });
      const card = await createCard(owner, cleanup, deck.id, {
        title: "Completion card",
        position: 1000,
      });
      // Grant the guest so they're allowed to write a completion for the card.
      const grant = await owner.collection("deck_guests").create({
        deck: deck.id,
        user: guestId,
        granted_at: nowIso(),
      });
      cleanup.track(owner, "deck_guests", grant.id);

      const ownerDone = await owner.collection("card_completions").create({
        card: card.id,
        user: ownerId,
        state: "done",
        changed_at: nowIso(),
      });
      cleanup.track(owner, "card_completions", ownerDone.id);

      const guestSkipped = await guest.collection("card_completions").create({
        card: card.id,
        user: guestId,
        state: "skipped",
        changed_at: nowIso(),
      });
      cleanup.track(guest, "card_completions", guestSkipped.id);

      // Owner sees only their own completion record, not the guest's.
      const ownerList = await owner
        .collection("card_completions")
        .getFullList({ filter: `card = "${card.id}"` });
      expect(ownerList.map((c) => c.id)).toEqual([ownerDone.id]);
      await expectStatus(
        owner.collection("card_completions").getOne(guestSkipped.id),
        404,
      );

      // Guest sees only their own.
      const guestList = await guest
        .collection("card_completions")
        .getFullList({ filter: `card = "${card.id}"` });
      expect(guestList.map((c) => c.id)).toEqual([guestSkipped.id]);
    });

    it("rejects a completion the user does not own, an invalid state, and a duplicate (card,user)", async () => {
      const deck = await createDeck(owner, cleanup, { name: "Completion rules deck" });
      const card = await createCard(owner, cleanup, deck.id, {
        title: "Rules card",
        position: 1000,
      });

      // Owner cannot create a completion for the guest (user must be self).
      await expectStatus(
        owner.collection("card_completions").create({
          card: card.id,
          user: guestId,
          state: "done",
          changed_at: nowIso(),
        }),
        400,
      );

      // Invalid enum value rejected (state ∈ {done,skipped,pending}).
      await expectStatus(
        owner.collection("card_completions").create({
          card: card.id,
          user: ownerId,
          state: "maybe",
          changed_at: nowIso(),
        }),
        400,
      );

      // First valid completion succeeds.
      const c1 = await owner.collection("card_completions").create({
        card: card.id,
        user: ownerId,
        state: "pending",
        changed_at: nowIso(),
      });
      cleanup.track(owner, "card_completions", c1.id);

      // Composite-unique (card,user): a second one for the same pair fails.
      await expectStatus(
        owner.collection("card_completions").create({
          card: card.id,
          user: ownerId,
          state: "done",
          changed_at: nowIso(),
        }),
        400,
      );
    });
  });

  // ---- soft-delete filtering ---------------------------------------------

  describe("soft-delete filtering", () => {
    it("listDecks contract: deleted_at = '' excludes trashed; getDeck scopes it out", async () => {
      const live = await createDeck(owner, cleanup, { name: "Live deck" });
      const trashed = await createDeck(owner, cleanup, {
        name: "Trashed deck",
        deleted_at: nowIso(),
      });

      // Mirror deckApi.listDecks() filter.
      const listed = await owner
        .collection("decks")
        .getFullList({ filter: 'deleted_at = ""', sort: "-updated" });
      const ids = listed.map((d) => d.id);
      expect(ids).toContain(live.id);
      expect(ids).not.toContain(trashed.id);

      // Mirror deckApi.listTrashedDecks() filter.
      const trash = await owner
        .collection("decks")
        .getFullList({ filter: 'deleted_at != ""' });
      expect(trash.map((d) => d.id)).toContain(trashed.id);

      // Mirror deckApi.getDeck(): trashed deck reads as not-found when scoped.
      await expectStatus(
        owner
          .collection("decks")
          .getFirstListItem(`id = "${trashed.id}" && deleted_at = ""`),
        404,
      );
      // ...but a plain getOne still returns it (viewRule has no deleted_at),
      // which is exactly why deckApi.getDeck adds the filter.
      expect((await owner.collection("decks").getOne(trashed.id)).id).toBe(
        trashed.id,
      );
    });

    it("listCards contract: excludes soft-deleted cards", async () => {
      const deck = await createDeck(owner, cleanup, { name: "Card SD deck" });
      const liveCard = await createCard(owner, cleanup, deck.id, {
        title: "Live card",
        position: 1000,
      });
      const deletedCard = await createCard(owner, cleanup, deck.id, {
        title: "Deleted card",
        position: 2000,
        deleted_at: nowIso(),
      });

      const listed = await owner.collection("cards").getFullList({
        filter: `deck = "${deck.id}" && deleted_at = ""`,
        sort: "position",
      });
      const ids = listed.map((c) => c.id);
      expect(ids).toContain(liveCard.id);
      expect(ids).not.toContain(deletedCard.id);
    });
  });

  // ---- cascade deletes ----------------------------------------------------

  describe("cascade deletes", () => {
    it("hard-deleting a deck cascades to cards, card_images, guests, completions", async () => {
      const deck = await createDeck(owner, cleanup, { name: "Cascade deck" });
      const card = await createCard(owner, cleanup, deck.id, {
        title: "Cascade card",
        position: 1000,
      });

      const image = await createImage(owner, cleanup, card.id);

      const grant = await owner.collection("deck_guests").create({
        deck: deck.id,
        user: guestId,
        granted_at: nowIso(),
      });
      const completion = await owner.collection("card_completions").create({
        card: card.id,
        user: ownerId,
        state: "done",
        changed_at: nowIso(),
      });

      // Hard delete the deck (not the soft-delete UI path — verifying the
      // server cascade rules the schema declares).
      await owner.collection("decks").delete(deck.id);

      await expectStatus(owner.collection("cards").getOne(card.id), 404);
      await expectStatus(
        owner.collection("card_images").getOne(image.id),
        404,
      );
      await expectStatus(
        owner.collection("deck_guests").getOne(grant.id),
        404,
      );
      await expectStatus(
        owner.collection("card_completions").getOne(completion.id),
        404,
      );
    });

    it("deleting a card cascades to its card_images", async () => {
      const deck = await createDeck(owner, cleanup, { name: "Card cascade deck" });
      const card = await createCard(owner, cleanup, deck.id, {
        title: "Card with image",
        position: 1000,
      });
      const image = await createImage(owner, cleanup, card.id);

      await owner.collection("cards").delete(card.id);
      await expectStatus(
        owner.collection("card_images").getOne(image.id),
        404,
      );
    });
  });

  // ---- required-field validation -----------------------------------------

  describe("required-field validation", () => {
    it("deck requires name and owner; rejects name over 200 chars", async () => {
      // Missing name.
      await expectStatus(
        owner.collection("decks").create({
          owner: ownerId,
          shoot_date: "",
          deleted_at: "",
          client_updated_at: nowIso(),
        }),
        400,
      );
      // Missing owner.
      await expectStatus(
        owner.collection("decks").create({
          name: "No owner",
          shoot_date: "",
          deleted_at: "",
          client_updated_at: nowIso(),
        }),
        400,
      );
      // name max 200.
      await expectStatus(
        owner.collection("decks").create({
          owner: ownerId,
          name: "x".repeat(201),
          shoot_date: "",
          deleted_at: "",
          client_updated_at: nowIso(),
        }),
        400,
      );
    });

    it("card requires deck and title; rejects title over 200 chars", async () => {
      const deck = await createDeck(owner, cleanup, { name: "Validation deck" });
      // Missing title.
      await expectStatus(
        owner.collection("cards").create({
          deck: deck.id,
          position: 1000,
          deleted_at: "",
          client_updated_at: nowIso(),
        }),
        400,
      );
      // Missing deck relation.
      await expectStatus(
        owner.collection("cards").create({
          title: "Orphan",
          position: 1000,
          deleted_at: "",
          client_updated_at: nowIso(),
        }),
        400,
      );
      // title max 200.
      await expectStatus(
        owner.collection("cards").create({
          deck: deck.id,
          title: "t".repeat(201),
          position: 1000,
          deleted_at: "",
          client_updated_at: nowIso(),
        }),
        400,
      );
    });
  });

  // ---- reorder / position behaviour --------------------------------------

  describe("reorder / position behaviour", () => {
    it("restripes positions to integer gaps following the new order", async () => {
      const deck = await createDeck(owner, cleanup, { name: "Reorder deck" });
      const a = await createCard(owner, cleanup, deck.id, {
        title: "A",
        position: 1000,
      });
      const b = await createCard(owner, cleanup, deck.id, {
        title: "B",
        position: 2000,
      });
      const c = await createCard(owner, cleanup, deck.id, {
        title: "C",
        position: 3000,
      });

      // Reverse order: C, B, A → positions 1000, 2000, 3000.
      const orderedIds = [c.id, b.id, a.id];
      const GAP = 1000;
      for (let i = 0; i < orderedIds.length; i++) {
        await owner.collection("cards").update(orderedIds[i], {
          position: (i + 1) * GAP,
          client_updated_at: nowIso(),
        });
      }

      const listed = await owner.collection("cards").getFullList({
        filter: `deck = "${deck.id}" && deleted_at = ""`,
        sort: "position",
      });
      expect(listed.map((card) => card.id)).toEqual([c.id, b.id, a.id]);
      expect(listed.map((card) => card.position)).toEqual([1000, 2000, 3000]);
    });

    it("appends a new card at last position + gap", async () => {
      const deck = await createDeck(owner, cleanup, { name: "Append deck" });
      await createCard(owner, cleanup, deck.id, { title: "First", position: 1000 });
      await createCard(owner, cleanup, deck.id, { title: "Second", position: 2000 });

      const existing = await owner.collection("cards").getFullList({
        filter: `deck = "${deck.id}" && deleted_at = ""`,
        sort: "position",
      });
      const maxPos = Math.max(...existing.map((c) => c.position));
      const appended = await createCard(owner, cleanup, deck.id, {
        title: "Third",
        position: maxPos + 1000,
      });
      expect(appended.position).toBe(3000);
    });
  });
});
