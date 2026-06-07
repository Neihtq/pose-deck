/**
 * INTEGRATION: server contracts the M3 SYNC layer relies on.
 *
 * Runs against a LIVE PocketBase (ephemeral, started by globalSetup) with the
 * version-controlled migrations + dev seed applied. The M1 contract test
 * (`contract.integration.test.ts`) already pins API rules / soft-delete /
 * cascade / required-field / reorder. This file pins the NEW server behaviour
 * the sync engine, realtime manager, and local store added in M3 ASSUME — the
 * ones that, if the server diverged, would silently break offline-first sync:
 *
 *  - CLIENT-SUPPLIED IDS on create (ids.ts / serverEntities.send): PocketBase
 *    accepts a caller-minted 15-char id on POST and returns it verbatim, for
 *    every synced collection that the outbox creates. The whole "local id ==
 *    server id, no temp-id reconciliation" design rests on this.
 *  - IDEMPOTENT CREATE REPLAY: re-POSTing the same id returns 400 with a
 *    `data.id` validation error — exactly the shape `isDuplicateIdError`
 *    matches and `send` reclassifies as success after a lost ack.
 *  - LWW CLOCK ROUND-TRIP: `client_updated_at` (decks/cards) and `changed_at`
 *    (card_completions) persist and are returned unchanged, so `mergeRecord`'s
 *    last-write-wins comparison has the field it orders by.
 *  - HYDRATE FETCHER CONTRACT: a plain `getFullList` (no `deleted_at` filter)
 *    returns soft-deleted rows too, which `hydrateFromServer` depends on to
 *    reconcile trashed decks into the trash view and to converge soft-deletes.
 *  - GUEST WRITE → DROP-CLASS 4xx: a guest mutating a granted deck fails with a
 *    4xx (not 401/5xx), so the engine `drop`s + rolls back rather than wedging
 *    the FIFO queue or pausing for re-auth.
 *  - REALTIME SUBSCRIBE + RULE SCOPING (realtimeManager): the SDK `subscribe`
 *    over live SSE delivers create/update/delete events for records the
 *    subscriber can see, and does NOT leak another owner's records to a guest
 *    who has no grant.
 *
 * Idempotent: every created record is tracked and cleaned up; children cascade
 * with their parent. The seeded DB is left as found.
 */
import PocketBase from "pocketbase";
import {
  afterEach,
  beforeAll,
  describe,
  expect,
  inject,
  it,
} from "vitest";

import {
  authGuest,
  authOwner,
  Cleanup,
  createCard,
  createDeck,
  nowIso,
} from "./harness";
import { isClientId, newClientId } from "@/lib/ids";

const pbUrl = inject("pbUrl");
const pbSkipReason = inject("pbSkipReason");

const d = pbUrl ? describe : describe.skip;
if (!pbUrl) {
  // eslint-disable-next-line no-console
  console.warn(`[integration:sync] SKIPPED: ${pbSkipReason}`);
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

d("M3 sync server contracts", () => {
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

  // ---- client-supplied ids ------------------------------------------------

  describe("client-supplied record ids on create", () => {
    it("decks: server accepts a minted 15-char id and returns it verbatim", async () => {
      const id = newClientId();
      expect(isClientId(id)).toBe(true);

      const rec = await owner.collection("decks").create({
        id,
        owner: ownerId,
        name: "Client-id deck",
        shoot_date: "",
        deleted_at: "",
        client_updated_at: nowIso(),
      });
      cleanup.track(owner, "decks", rec.id);

      // The whole sync design (no temp-id reconciliation) depends on this.
      expect(rec.id).toBe(id);
      // And a fresh read still has that id.
      expect((await owner.collection("decks").getOne(id)).id).toBe(id);
    });

    it("cards & card_completions also accept client-minted ids (full outbox surface)", async () => {
      const deck = await createDeck(owner, cleanup, { name: "Client-id parents" });

      const cardId = newClientId();
      const card = await owner.collection("cards").create({
        id: cardId,
        deck: deck.id,
        title: "Client-id card",
        position: 1000,
        deleted_at: "",
        client_updated_at: nowIso(),
      });
      cleanup.track(owner, "cards", card.id);
      expect(card.id).toBe(cardId);

      const completionId = newClientId();
      const completion = await owner.collection("card_completions").create({
        id: completionId,
        card: cardId,
        user: ownerId,
        state: "done",
        changed_at: nowIso(),
      });
      cleanup.track(owner, "card_completions", completion.id);
      expect(completion.id).toBe(completionId);
    });
  });

  // ---- idempotent create replay -------------------------------------------

  describe("idempotent create replay (lost-ack contract)", () => {
    it("re-POSTing an existing id fails 400 with a data.id error (isDuplicateIdError shape)", async () => {
      const id = newClientId();
      const first = await owner.collection("decks").create({
        id,
        owner: ownerId,
        name: "Replay deck",
        shoot_date: "",
        deleted_at: "",
        client_updated_at: nowIso(),
      });
      cleanup.track(owner, "decks", first.id);

      // The sync engine's `send` retries a create after a lost 2xx; the second
      // POST must surface as a 400 whose response.data has an `id` key, which
      // `isDuplicateIdError` matches and reclassifies as success.
      try {
        await owner.collection("decks").create({
          id,
          owner: ownerId,
          name: "Replay deck (dup)",
          shoot_date: "",
          deleted_at: "",
          client_updated_at: nowIso(),
        });
        throw new Error("expected duplicate-id create to fail");
      } catch (err) {
        const e = err as { status?: number; response?: { data?: Record<string, unknown> } };
        expect(e.status).toBe(400);
        expect(e.response?.data).toBeTruthy();
        expect(e.response?.data && "id" in e.response.data).toBe(true);
      }

      // The original record is intact (name unchanged — the dup did not edit it).
      expect((await owner.collection("decks").getOne(id)).name).toBe("Replay deck");
    });
  });

  // ---- LWW clock round-trip -----------------------------------------------

  describe("LWW clock fields round-trip", () => {
    it("decks/cards persist client_updated_at; updating it returns a newer value", async () => {
      const t0 = nowIso();
      const deck = await createDeck(owner, cleanup, { name: "Clock deck" });
      // createDeck stamps client_updated_at; it must come back as a non-empty
      // string (mergeRecord's LWW needs this field present).
      expect(typeof deck.client_updated_at).toBe("string");
      expect((deck.client_updated_at as string).length).toBeGreaterThan(0);

      // Bump the clock via an update and confirm the server echoes a strictly
      // GREATER value (mergeRecord orders by string-comparing exactly this
      // field). We compare normalized forms because PocketBase reformats the
      // datetime (see the dedicated datetime-format contract test below) — what
      // matters for LWW is monotonic string ordering, which holds within the
      // server's own consistent format.
      const t1 = new Date(Date.parse(t0) + 1000).toISOString();
      const updated = await owner.collection("decks").update(deck.id, {
        name: "Clock deck v2",
        client_updated_at: t1,
      });
      expect(typeof updated.client_updated_at).toBe("string");
      expect(
        (updated.client_updated_at as string) > (deck.client_updated_at as string),
      ).toBe(true);
    });

    it("card_completions persist changed_at (their LWW clock, not client_updated_at)", async () => {
      const deck = await createDeck(owner, cleanup, { name: "Completion clock deck" });
      const card = await createCard(owner, cleanup, deck.id, {
        title: "Completion clock card",
        position: 1000,
      });
      const ts = nowIso();
      const completion = await owner.collection("card_completions").create({
        card: card.id,
        user: ownerId,
        state: "pending",
        changed_at: ts,
      });
      cleanup.track(owner, "card_completions", completion.id);
      expect(typeof completion.changed_at).toBe("string");
      expect((completion.changed_at as string).length).toBeGreaterThan(0);

      const ts2 = new Date(Date.parse(ts) + 1000).toISOString();
      const moved = await owner.collection("card_completions").update(completion.id, {
        state: "done",
        changed_at: ts2,
      });
      expect((moved.changed_at as string) > (completion.changed_at as string)).toBe(true);
      expect(moved.state).toBe("done");
    });

    it("CONTRACT: PocketBase normalizes ISO datetimes (T → space) on round-trip", async () => {
      // The data layer stamps client_updated_at as a JS ISO string
      // (`2026-06-07T07:55:04.281Z`), but PocketBase stores + returns it with a
      // SPACE separator (`2026-06-07 07:55:04.281Z`). This is load-bearing for
      // the realtime self-echo path (recentlyConfirmed.ts): the confirmed clock
      // we mark is the T-form we sent, while the realtime echo carries the
      // space-form. Because space (0x20) < 'T' (0x54), the space-form echo is
      // NOT > the marked T-form clock, so `shouldSuppress` still suppresses our
      // own echo (does not treat it as a strictly-newer concurrent write). If a
      // future PocketBase changed this normalization, that assumption — and LWW
      // self-echo suppression — would silently break. Pin it here.
      const sent = "2026-06-07T07:55:04.281Z";
      const deck = await owner.collection("decks").create({
        owner: ownerId,
        name: "Datetime fmt deck",
        shoot_date: "",
        deleted_at: "",
        client_updated_at: sent,
      });
      cleanup.track(owner, "decks", deck.id);

      const returned = deck.client_updated_at as string;
      // Same instant, different textual separator.
      expect(returned).toBe("2026-06-07 07:55:04.281Z");
      expect(Date.parse(returned)).toBe(Date.parse(sent));
      // The space-form does NOT sort after the T-form (self-echo invariant).
      expect(returned > sent).toBe(false);
    });
  });

  // ---- hydrate fetcher contract -------------------------------------------

  describe("hydrate fetcher contract (getFullList sees soft-deleted rows)", () => {
    it("an unfiltered getFullList returns BOTH live and soft-deleted decks", async () => {
      const live = await createDeck(owner, cleanup, { name: "Hydrate live" });
      const trashed = await createDeck(owner, cleanup, {
        name: "Hydrate trashed",
        deleted_at: nowIso(),
      });

      // hydrateFromServer fetches ALL viewable rows (no deleted_at filter) so
      // trashed decks reconcile into the trash view and soft-deletes converge.
      const all = await owner.collection("decks").getFullList({ sort: "-updated" });
      const ids = all.map((r) => r.id);
      expect(ids).toContain(live.id);
      expect(ids).toContain(trashed.id);

      // The trashed row carries a non-empty deleted_at so the local filter works.
      const trashedRow = all.find((r) => r.id === trashed.id)!;
      expect(typeof trashedRow.deleted_at).toBe("string");
      expect(trashedRow.deleted_at).not.toBe("");
    });
  });

  // ---- guest write → drop-class 4xx ---------------------------------------

  describe("guest write on a granted deck is a drop-class 4xx (engine must not wedge)", () => {
    it("guest update/create on a granted deck fails 4xx, never 401/5xx", async () => {
      const deck = await createDeck(owner, cleanup, { name: "Guest drop deck" });
      const card = await createCard(owner, cleanup, deck.id, {
        title: "Guest drop card",
        position: 1000,
      });
      const grant = await owner.collection("deck_guests").create({
        deck: deck.id,
        user: guestId,
        granted_at: nowIso(),
      });
      cleanup.track(owner, "deck_guests", grant.id);

      // Guest can now READ, but a write must be a 4xx the engine classifies as
      // `drop` (status >= 400 && < 500, not 401, not >=500). serverEntities
      // would otherwise pause (401) or retry forever (5xx) and wedge the queue.
      const assertDropClass = (status: number | undefined) => {
        expect(typeof status).toBe("number");
        expect(status!).toBeGreaterThanOrEqual(400);
        expect(status!).toBeLessThan(500);
        expect(status).not.toBe(401);
      };

      try {
        await guest.collection("cards").update(card.id, {
          title: "hijack",
          client_updated_at: nowIso(),
        });
        throw new Error("expected guest update to fail");
      } catch (err) {
        assertDropClass((err as { status?: number }).status);
      }

      try {
        await guest.collection("cards").create({
          deck: deck.id,
          title: "guest insert",
          position: 2000,
          deleted_at: "",
          client_updated_at: nowIso(),
        });
        throw new Error("expected guest create to fail");
      } catch (err) {
        assertDropClass((err as { status?: number }).status);
      }
    });
  });

  // ---- realtime subscribe + rule scoping ----------------------------------

  describe("realtime subscribe delivers events scoped by API rules", () => {
    it("owner receives create/update/delete events on their own deck", async () => {
      const events: Array<{ action: string; id: string }> = [];
      // realtimeManager subscribes '*' per collection; mirror that here.
      const unsub = await owner.collection("decks").subscribe("*", (e) => {
        events.push({ action: e.action, id: e.record.id });
      });

      try {
        const id = newClientId();
        const rec = await owner.collection("decks").create({
          id,
          owner: ownerId,
          name: "Realtime deck",
          shoot_date: "",
          deleted_at: "",
          client_updated_at: nowIso(),
        });
        cleanup.track(owner, "decks", rec.id);

        await waitFor(() => events.some((e) => e.action === "create" && e.id === id));

        await owner.collection("decks").update(id, {
          name: "Realtime deck v2",
          client_updated_at: nowIso(),
        });
        await waitFor(() => events.some((e) => e.action === "update" && e.id === id));

        await owner.collection("decks").delete(id);
        await waitFor(() => events.some((e) => e.action === "delete" && e.id === id));
      } finally {
        await unsub();
      }
    });

    it("a guest with NO grant does not receive realtime events for the owner's deck", async () => {
      const guestEvents: Array<{ action: string; id: string }> = [];
      const unsub = await guest.collection("decks").subscribe("*", (e) => {
        guestEvents.push({ action: e.action, id: e.record.id });
      });

      try {
        const id = newClientId();
        const rec = await owner.collection("decks").create({
          id,
          owner: ownerId,
          name: "Private realtime deck",
          shoot_date: "",
          deleted_at: "",
          client_updated_at: nowIso(),
        });
        cleanup.track(owner, "decks", rec.id);

        // Give the server ample time to (not) deliver. The guest has no grant,
        // so the rule-scoped subscription must never see this record.
        await new Promise((r) => setTimeout(r, 1500));
        expect(guestEvents.some((e) => e.id === id)).toBe(false);
      } finally {
        await unsub();
      }
    });
  });
});
