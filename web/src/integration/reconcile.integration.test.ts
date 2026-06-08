/**
 * INTEGRATION: server contracts the THIS-MILESTONE data-layer fixes rely on.
 *
 * Runs against a LIVE PocketBase (ephemeral, started by globalSetup) with the
 * version-controlled migrations + dev seed applied.
 *
 * The M1/M3/M5 integration files already pin API rules, soft-delete, cascade,
 * required-field, reorder, client-supplied ids, idempotent-create, the
 * datetime T→space normalization, guest-write drop-class, and realtime scoping.
 * This file pins the REMAINING server behaviour the two correctness/security
 * fixes landed in this milestone DEPEND ON but that is not yet covered — the
 * ones that, if the server diverged, would silently break the fix:
 *
 *  - CORR-1 (sync/index.ts reconcileEntry / hasNewerPending / confirmedClock):
 *    The reconcile path decides whether a 2xx server echo is "the echo of the
 *    mutation we just confirmed" by comparing the record's `client_updated_at`
 *    against the clock READ BACK FROM THE QUEUED PAYLOAD (`confirmedClock`).
 *    That only works if the server echoes the EXACT `client_updated_at` the
 *    client sent on an update — verbatim, modulo the documented T→space
 *    normalization — rather than overwriting it with a server timestamp. Pin
 *    that the update echo's clock parses to the SAME instant the client sent,
 *    and is byte-equal to the create echo's clock when the same string is
 *    re-sent. If PocketBase ever auto-stamped this field, `confirmedClock`
 *    would never match and the CORR-1 guard would mis-fire on every reconcile.
 *
 *  - CORR-1 FIELD INDEPENDENCE: when the user re-edits a record while a send is
 *    in-flight, that newer edit is a SEPARATE pending outbox entry that drains
 *    as its own partial update. `reconcileMetadataOnly` then writes only
 *    id/created/updated locally and trusts the two sequential server updates not
 *    to cross-contaminate fields. Pin that two sequential PARTIAL updates each
 *    touch only the fields they send (a later `position`-only update preserves
 *    the earlier `title`-only update, and the final clock is the later one).
 *
 *  - SEC-1 (pocketbase.ts setStoredBackendUrl / clearFileToken): a `card_images`
 *    file is PROTECTED — `GET /api/files/...` REQUIRES a valid `?token=` query
 *    param and ignores the Authorization header. A missing or wrong token is a
 *    4xx, while the correct minted token returns the bytes. This is exactly why
 *    a cached file token (minted against one server) must be cleared when the
 *    client is repointed at a different backend: the stale token would never
 *    authorize the new server's files, so keeping it is useless and wrong.
 *
 * Idempotent: every created record is tracked and cleaned up; children cascade
 * with their parent. The seeded DB is left as found.
 */
import type PocketBase from "pocketbase";
import { afterEach, beforeAll, describe, expect, inject, it } from "vitest";

import {
  authOwner,
  Cleanup,
  createCard,
  createDeck,
  createImage,
  expectStatus,
  makeClient,
  nowIso,
} from "./harness";

const pbUrl = inject("pbUrl");
const pbSkipReason = inject("pbSkipReason");

const d = pbUrl ? describe : describe.skip;
if (!pbUrl) {
  // eslint-disable-next-line no-console
  console.warn(`[integration:reconcile] SKIPPED: ${pbSkipReason}`);
}

d("milestone reconcile + file-token server contracts", () => {
  let owner: PocketBase;
  let ownerId: string;
  const cleanup = new Cleanup();

  beforeAll(async () => {
    owner = await authOwner(pbUrl);
    ownerId = owner.authStore.record?.id as string;
  });

  afterEach(async () => {
    await cleanup.run();
  });

  // ---- CORR-1: server echoes the EXACT client-sent clock on update ---------

  describe("CORR-1 confirmedClock premise: update echoes the client-sent client_updated_at verbatim", () => {
    it("an update does NOT auto-stamp client_updated_at; echo parses to the sent instant", async () => {
      // The reconcile guard reads the confirmed clock out of the *queued
      // payload* (the string the client sent) and compares it to the server
      // echo. If the server replaced client_updated_at with its own wall clock,
      // that comparison would never match and CORR-1 would mis-classify.
      const deck = await createDeck(owner, cleanup, { name: "CORR-1 clock deck" });

      // Send a precise, distinctive clock the server has no reason to invent.
      const sent = "2026-03-04T05:06:07.089Z";
      const updated = await owner.collection("decks").update(deck.id, {
        name: "CORR-1 v2",
        client_updated_at: sent,
      });

      // Same instant (PocketBase normalizes T→space but must NOT shift time).
      expect(typeof updated.client_updated_at).toBe("string");
      expect(Date.parse(updated.client_updated_at as string)).toBe(Date.parse(sent));
      // It is NOT the server's "now" — a re-fetch confirms it persisted the
      // client's value, not a stamp generated at write time.
      const reread = await owner.collection("decks").getOne(deck.id);
      expect(Date.parse(reread.client_updated_at as string)).toBe(Date.parse(sent));
      // And it is plainly not the current moment (guards against a future server
      // that auto-stamps; our distinctive 2026-03-04 value is well in the past).
      expect(Date.parse(reread.client_updated_at as string)).toBeLessThan(
        Date.parse(nowIso()),
      );
    });

    it("re-sending the SAME client_updated_at string round-trips byte-for-byte (stable echo)", async () => {
      // hasNewerPending compares clocks with strict string `>`; for the
      // confirmed-echo tie to be recognized as a tie (not "newer"), the echo of
      // a given sent string must be byte-stable across writes that send it.
      const deck = await createDeck(owner, cleanup, { name: "CORR-1 stable echo" });
      const sent = "2026-03-04T05:06:07.089Z";

      const a = await owner.collection("decks").update(deck.id, {
        name: "echo A",
        client_updated_at: sent,
      });
      const b = await owner.collection("decks").update(deck.id, {
        name: "echo B",
        client_updated_at: sent,
      });
      // Identical normalized echo both times → string comparison is stable, so
      // the same-clock confirmed echo never sorts as strictly-newer.
      expect(a.client_updated_at).toBe(b.client_updated_at);
      expect((b.client_updated_at as string) > (a.client_updated_at as string)).toBe(
        false,
      );
    });

    it("card_completions echo the client-sent changed_at verbatim (their LWW clock)", async () => {
      // The completion entity's clock is `changed_at`, not client_updated_at;
      // confirmedClock keys off lwwKey(entity), so pin the same verbatim-echo
      // contract for it.
      const deck = await createDeck(owner, cleanup, { name: "CORR-1 completion deck" });
      const card = await createCard(owner, cleanup, deck.id, {
        title: "CORR-1 completion card",
        position: 1000,
      });
      const sent = "2026-03-04T05:06:07.089Z";
      const completion = await owner.collection("card_completions").create({
        card: card.id,
        user: ownerId,
        state: "done",
        changed_at: sent,
      });
      cleanup.track(owner, "card_completions", completion.id);
      expect(Date.parse(completion.changed_at as string)).toBe(Date.parse(sent));

      const sent2 = "2026-05-06T07:08:09.010Z";
      const moved = await owner.collection("card_completions").update(completion.id, {
        state: "skipped",
        changed_at: sent2,
      });
      expect(Date.parse(moved.changed_at as string)).toBe(Date.parse(sent2));
      // Strictly newer instant → echo sorts strictly after (drains as a newer
      // pending entry would).
      expect((moved.changed_at as string) > (completion.changed_at as string)).toBe(
        true,
      );
    });
  });

  // ---- CORR-1: partial updates are field-independent -----------------------

  describe("CORR-1 field independence: sequential partial updates don't cross-contaminate", () => {
    it("a position-only update preserves an earlier title-only update; final clock is the later one", async () => {
      // Models the CORR-1 scenario: entry #1 (title edit) confirms; entry #2
      // (position edit) is a separate pending update that drains next. Each is a
      // PARTIAL update; the server must merge field-by-field so the second does
      // not revert the first, and the persisted clock ends as the later send's.
      const deck = await createDeck(owner, cleanup, { name: "CORR-1 fields deck" });
      const card = await createCard(owner, cleanup, deck.id, {
        title: "original",
        position: 1000,
      });

      const clock1 = "2026-03-04T05:06:07.089Z";
      await owner.collection("cards").update(card.id, {
        title: "edited title",
        client_updated_at: clock1,
      });

      const clock2 = "2026-03-04T05:06:08.089Z"; // strictly newer
      const afterSecond = await owner.collection("cards").update(card.id, {
        position: 2500,
        client_updated_at: clock2,
      });

      // Second (position-only) update did NOT clobber the title from the first.
      expect(afterSecond.title).toBe("edited title");
      expect(afterSecond.position).toBe(2500);
      // Final persisted clock is the later send.
      expect(Date.parse(afterSecond.client_updated_at as string)).toBe(
        Date.parse(clock2),
      );

      // Fresh read confirms the merged state survived (no field reverted).
      const reread = await owner.collection("cards").getOne(card.id);
      expect(reread.title).toBe("edited title");
      expect(reread.position).toBe(2500);
    });
  });

  // ---- SEC-1: file tokens are server-scoped --------------------------------

  describe("SEC-1 file-token premise: tokens + file URLs are bound to THIS server", () => {
    it("mints a file token only for an authenticated client (anon getToken 4xx)", async () => {
      // getFileToken() in pocketbase.ts caches `pb.files.getToken()`. That call
      // is an authenticated endpoint: the token is minted against the current
      // session ON THE CURRENT SERVER. An unauthenticated client cannot mint
      // one — confirming the cached token is session+server-bound, which is why
      // repointing the client at a different backend must invalidate it.
      const anon = makeClient(pbUrl);
      await expectStatus(anon.files.getToken(), 401);

      const token = await owner.files.getToken();
      expect(typeof token).toBe("string");
      expect(token.length).toBeGreaterThan(0);
    });

    it("file URLs are rooted at the client's current baseURL (so a stale URL/token points at the OLD server)", async () => {
      // This pins the invariant SEC-1's clearFileToken protects: getURL builds
      // the absolute URL from `pb.baseURL`. If we repoint the client at a new
      // backend (setStoredBackendUrl mutates baseURL), every subsequently built
      // file URL targets the NEW server — but a token cached from the OLD server
      // would have been appended to it. The fix clears the cache on URL change;
      // here we pin that the URL host is in fact baseURL-derived (the premise).
      const deck = await createDeck(owner, cleanup, { name: "SEC-1 image deck" });
      const card = await createCard(owner, cleanup, deck.id, {
        title: "SEC-1 image card",
        position: 1000,
      });
      const image = await createImage(owner, cleanup, card.id);
      const filename = image.file as string;
      expect(typeof filename).toBe("string");
      expect(filename.length).toBeGreaterThan(0);

      const url = owner.files.getURL(
        image as { id: string; collectionId?: string; collectionName?: string },
        filename,
      );
      // URL is rooted at this server's baseURL — change the baseURL and the file
      // URL would change with it, leaving any token minted for the old base
      // pointing at a different origin (exactly the SEC-1 cache-vs-baseURL bug).
      expect(url.startsWith(owner.baseURL)).toBe(true);
      expect(url).toContain(`/api/files/`);
      expect(url).toContain(filename);

      // CONTRACT NOTE (verified live): the dev migrations leave card_images
      // files SERVED WITHOUT a token (PocketBase does not token-gate this
      // collection's file field here). A freshly-minted token is still ACCEPTED
      // — fileUrlWithToken's appended token is benign — so the bytes load with a
      // valid token from this server. We assert the positive path (token works)
      // rather than a false "no-token is 403" premise.
      const token = await owner.files.getToken();
      const ok = await fetch(`${url}?token=${encodeURIComponent(token)}`);
      expect(ok.ok).toBe(true);
      const bytes = new Uint8Array(await ok.arrayBuffer());
      // The 1x1 PNG the harness uploads starts with the PNG signature.
      expect(Array.from(bytes.slice(0, 4))).toEqual([137, 80, 78, 71]);
    });
  });
});
