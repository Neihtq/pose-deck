# M5 Sharing — Implementation Plan (vetted via design+adversarial-review 2026-06-07)

All eight adversarial findings are confirmed against the actual code. `isDuplicateIdError` (serverEntities.ts:82-85) only inspects `data.id` — a composite-unique `(deck,user)` 400 won't match, confirming finding #6. `lwwKey` returns undefined for `deck_guests` (line 167), confirming the no-LWW pattern. Both web trash (`liveTrashedDecks`, no owner filter) and iOS trash (`listTrashedDecks`, no owner filter) confirm finding #3.

Here is the consolidated plan.

---

# M5 SHARING — CONSOLIDATED IMPLEMENTATION PLAN (vetted)

Per ARCHITECTURE.md §6/§3.5: `deck_guests` grant/revoke, NO share-link/QR. Backend `deck_guests` collection + decks/cards/card_images guest-visibility rules already exist and are integration-tested. This plan folds in all 8 adversarial review findings (2 critical, 3 major, 3 minor), noting each inline as **[FIX #n]**.

**Code-verified facts driving the revisions:**
- Web deck list IS mirror-backed: `DeckListPage.tsx:161` → `liveDecks(db)` → `db.decks.toArray()` (localStore.ts:384). Identical to iOS. ⇒ findings #1/#2 are real, web fixes are MANDATORY not conditional.
- `isDuplicateIdError` (serverEntities.ts:82-85) only checks `data.id`; a `(deck,user)` unique violation is keyed on relation fields ⇒ classified as hard `drop`. Finding #6 confirmed.
- `lwwKey` returns `undefined` for `deck_guests` (serverEntities.ts:167) ⇒ insert/hard-delete pattern, no `client_updated_at`. Correct as designed.
- Both `liveTrashedDecks` (web, localStore.ts:389) and `listTrashedDecks` (iOS, MirrorRepositories.swift:57) lack an owner filter. Finding #3 confirmed on both platforms.
- iOS `cascadeDeckRemoval` exists (SyncEngine.swift:201); `applyDeckGuest` at :175; `revokeGuest` at OfflineWritePath.swift:301; `backfill(ownerId:)` at SyncCoordinator.swift:198 with `ticker`/`ownerId` already held.

---

## PHASE A — BACKEND (verify-first; agent-runnable in THIS env against live dev PB with POSEDECK_DEV=true)

### A1. New migration — `backend/pb_migrations/1700000008_users_email_lookup.js` (NEW)
- **up:** set `users.listRule` = `id = @request.auth.id || (@request.auth.id != "" && email = @request.query.email)`. Leave viewRule/createRule/updateRule/deleteRule unchanged.
- **down:** revert listRule to `id = @request.auth.id`.
- **[FIX #5]** Add a migration comment documenting the existence-oracle tradeoff (any authenticated user can confirm whether an email has an account, 1 row vs 0). Acceptable for the 2-user private model. Also note this in ARCHITECTURE.md §3.1 (the "list/view only own record" contract is now relaxed for list-by-exact-email).
- No change to `deck_guests` rules (create/update/delete = `deck.owner = @request.auth.id`; list/view = `deck.owner = @request.auth.id || user = @request.auth.id`) — already correct. No change to dev seed (`guest@posedeck.test` exists).

### A2. Extend `web/.../contract.integration.test.ts` deck_guests describe (live PB) — RUNS in this env
Assert the rule properties before any client work:
- Owner resolves `guest@posedeck.test` by email via new listRule → returns the guest id.
- **[FIX #5]** Owner `getFullList(users)` with NO email filter → returns only self (enumeration blocked).
- **[FIX #5]** `list(users, filter email="<guest>" + query email=<guest>)` → exactly one row. Verify against real PB that `@request.query.email` evaluates as expected (absent param = empty, not match-any).
- Owner `getOne(guestId)` still 404s (viewRule unchanged).
- Owner grant → guest reads deck → owner revoke → guest `getOne(deck)` 404s.
- **[FIX #6]** Duplicate grant (same deck,user) → composite-unique 400.

**Gate:** run this suite green before touching any client code.

---

## PHASE B — WEB (agent-full verifiable in this env)

### B1. `web/src/lib/localStore.ts` (edit)
- Add `liveDeckGuests(db, deckId)`: `db.deck_guests.where('deck').equals(deckId).toArray()` sorted by `granted_at`.
- **[FIX #3]** Change `liveTrashedDecks` to accept `ownerId` and filter `d.owner === ownerId` (a guest must not see an owner's trashed shared deck). Update the single caller (Trash view) to pass the auth user id.
- **[FIX #8]** Add `'deck_guests'` to the `recentlyCreatedIds` buckets (localStore.ts:260) so optimistic grants survive the create-prune race, matching decks/cards. (Cheapest correct option; the design's "pendingRecordIds already covers it" was incomplete.)

### B2. `web/src/lib/serverEntities.ts` (edit) — **[FIX #6]**
- Extend duplicate-as-success handling: in `send`'s catch for `create`, treat a `deck_guests` `(deck,user)` unique-constraint 400 as idempotent success (not a hard drop). Either broaden `isDuplicateIdError` to recognize the deck_guests unique-index error shape, or special-case `entry.entity === 'deck_guests'` + 400. Prevents the "change could not be saved" toast + erroneous optimistic rollback on re-grant races.

### B3. `web/src/features/decks/guestApi.ts` (NEW)
- `resolveUserByEmail(email)`: `pb.collection('users').getFullList({ filter: 'email = "<email>"', query: { email } })` → single user id or null.
- `grantGuest(deckId, email)`: resolve id → mint client id (`newClientId`) → optimistic `db.deck_guests.put` → `markRecentlyCreated('deck_guests', id)` **[FIX #8]** → `enqueueCoalesced` create (payload `{deck, user, granted_at}`, no `client_updated_at`) → `wakeSync()`.
- `revokeGuest(guestId)`: `db.deck_guests.delete` (hard) → `enqueueCoalesced` delete → `wakeSync()`. Grant-then-revoke coalesces to a no-op.

### B4. `web/src/sync/realtimeManager.ts` (edit) — **[FIX #1 + FIX #2, both now MANDATORY]**
The design's premise that "web reads a live PB list" is FALSE; web has the same mirror gap as iOS.
- **[FIX #1] mid-session grant:** in `applyEvent`, when `entity === 'deck_guests' && action === 'create'`, after `mergeRecord`, if the granted `record.user === currentAuthUserId` AND the deck row is absent locally → trigger `this.resync()` (which calls `hydrateFromServer`, line 116-118) so the now-visible deck + cards + images enter Dexie and `liveDecks` re-queries. Gate to the absent-deck case (and/or debounce) to avoid redundant resyncs.
- **[FIX #2] mid-session revoke:** on `entity === 'deck_guests' && action === 'delete'`, if the revoked `record.user === currentAuthUserId` AND the local deck's `owner !== currentAuthUserId`, cascade-evict locally: remove the deck row + its cards + card_images + image_blobs/pin from Dexie. **[FIX #7-web]** Resolve owner from the local deck row FIRST; if the deck row is absent, do nothing (can't confirm foreign-owned ⇒ never evict). This protects an owner who revokes their own guest.

### B5. `web/src/features/decks/ShareDeckDialog.tsx` (NEW)
- Owner-only dialog. Live list of current guests via `liveDeckGuests(db, deckId)`, each with a Revoke button.
- "Add by email" input + Share button → `guestApi.grantGuest`.
- Guards: not-found email ("No user with that email"); duplicate (pre-check existing local guests, surface "already shared") **[FIX #6 client side]**; self-share (reject `email === current user's email`) **[FIX #4]** so the owner never creates a self-grant that would trip hydration.
- Errors via toast; `clearAuthOnUnauthorized` on 401.

### B6. `web/src/features/decks/DeckDetailPage.tsx` (edit) — **[FIX, owner-only gating]**
- Add "Share" to the header DropdownMenu, rendered ONLY when `deck.owner === useAuth().user.id`.
- Gate Rename/Duplicate/Delete the same way (guests are read-only). At minimum hide Share/Delete/Rename for non-owners.

### Web test layers
- **Component (vitest/RTL) — RUNS:** ShareDeckDialog (render guests; add-by-email happy path; not-found; duplicate blocked; self-share blocked; revoke removes row). DeckDetailPage (Share visible for owner, ABSENT for guest viewer).
- **Unit (guestApi.test.ts) — RUNS:** resolveUserByEmail builds filter+query; grantGuest writes optimistic row + marks recentlyCreated + enqueues create (no `client_updated_at`); revokeGuest hard-deletes + enqueues delete; grant-then-revoke coalescing cancels create. **[FIX #6]** serverEntities test: deck_guests `(deck,user)` 400 → success, no rollback. **[FIX #8]** create-prune race test: optimistic guest survives a racing resync.
- **realtimeManager unit — RUNS [FIX #1/#2/#7-web]:** deck_guests create for me + deck absent → resync triggered; create for me + deck present → no resync; delete revoking me + foreign owner → deck+cards+images evicted; delete where I own the deck → deck kept; delete with absent deck row → no-op.
- **Integration — RUNS (Phase A2 suite).**
- **E2E (Playwright if present) — SKIP if no Playwright harness in this env; otherwise RUNS:** owner Share → guest (second context) sees deck live; owner revoke → guest's deck disappears live and the open deck view errors/redirects.

---

## PHASE C — iOS (UI + close the deck_guests consumption gap; swift test + xcodebuild verifiable)

### C1. `ios/PoseDeckCore/.../Repositories/DeckGuestRepository.swift` (NEW)
- `listGuests()` → `client.listAll(DeckGuest.self, collection: "deck_guests", perPage: 200)` (listRule scopes to owner+guest).
- `resolveUser(byEmail:)` → `client.list(User.self, collection: "users", filter: 'email = "<quoted>"', query: ["email": email])` → single user id or nil. Parity with web resolveUserByEmail.

### C2. `ios/PoseDeckCore/.../Sync/OfflineWritePath.swift` (edit)
- Add `grantGuest(deckId:userId:)`: mint client id → optimistic `DeckGuest(grantedAt: now)` → `store.upsertDeckGuest` → enqueue `.create` entity `deck_guests` with `DeckGuestCreateWire {id, deck, user, granted_at}`. Mirrors `createCard`'s no-LWW insert.
- **[FIX #6-iOS]** grantGuest does idempotent handling of a `(deck,user)` unique 400 (silent no-op, no error). `revokeGuest` already exists (line 301).

### C3. `ios/PoseDeckCore/.../Sync/SyncEngine.swift` (edit) — closes the M3-deferred gap
- **Inject `currentUserId`** (store it; set on init / setter on re-auth). Needed for guest-vs-owner decisions.
- **(B) applyDeckGuest CREATE:** store the row; then if `guest.user == currentUserId` AND `store.deck(id: guest.deck)` is absent/needs-hydration → invoke new callback `onGuestDeckNeedsHydration?(deckId)`. **[FIX #4]** First check `store.deck(id:)` — if deck+cards already present and live, SKIP (no-op). Owner echo (`user != currentUserId`) → store row only, no refetch. Debounce/coalesce concurrent hydration per deckId.
- **(C) applyDeckGuest DELETE:** after `hardDeleteDeckGuest`, **[FIX #7-iOS]** evict ONLY when `store.deck(id:)` exists AND `deck.owner != currentUserId` (positively-resolved foreign owner). If deck row absent → do nothing. If I own the deck → keep it (owner revoking their own guest). Reuse `cascadeDeckRemoval` (SyncEngine.swift:201). Combine with self-echo suppression (recentlyConfirmed).

### C4. `ios/PoseDeck/Sources/Sync/SyncCoordinator.swift` (edit)
- Pass authenticated user id into SyncEngine (init or in `onAuthenticated`, which already holds `ownerId`).
- **(A) backfill deck_guests:** in `backfill(ownerId:)` (line 198), after decks/cards/completions, `DeckGuestRepository.listGuests()` → `upsertDeckGuest` each → reconcile-prune mirror guests not in server set (parity with web reconcileEntity).
- **[FIX #3-iOS]** backfill calls `listTrashedDecks()` (line 204) with no owner clause — the decks listRule grants guests visibility to owner's trashed shared decks. Owner-scope the iOS Trash so a guest never sees/restores them (see C7).
- Implement `engine.onGuestDeckNeedsHydration = { deckId in fetch DeckRepository.getDeck + CardRepository.listCards + images → upsert → ticker.bump() }` so a mid-session grant makes the deck appear live.

### C5. `ios/PoseDeck/Sources/Sync/MirrorRepositories.swift` (edit)
- Add `MirrorDeckGuestRepository` (or extend MirrorDeckRepository): `listGuests(deckId:)` → `store.deckGuests(deckId:)`; `grantGuest(deckId:email:)` → `DeckGuestRepository.resolveUser(byEmail:)` then `writePath.grantGuest`; `revokeGuest(guest:)` → `writePath.revokeGuest`. App-side protocol `DeckGuestRepositoring`.
- **[FIX #3-iOS]** `listTrashedDecks()` (line 57): filter to `deck.owner == currentUserId` so a guest's Trash never surfaces an owner's trashed shared deck (and can't issue an illegal restore PATCH that 403s).

### C6. `ios/PoseDeck/Sources/Decks/DeckDetailViewModel.swift` (edit)
- Add `loadGuests`, `grantGuest(email:)`, `revokeGuest` delegating to the mirror guest repo. **[FIX #4]** self-share guard (reject `email == current user's email`). Add `isOwner = (deck.owner == ownerId)`. Surface grant/revoke errors via `actionError`.

### C7. `ios/PoseDeck/Sources/Decks/ShareDeckView.swift` (NEW)
- Owner-only SwiftUI share sheet: current guests (`store.deckGuests`, re-queried on `ticker.revision`) with swipe/Revoke; "Add by email" → grantGuest. Handles not-found, duplicate (pre-check), self-share.

### C8. `ios/PoseDeck/Sources/Decks/DeckDetailView.swift` (edit) — **[owner-only gating]**
- Add "Share" toolbar/menu item presenting ShareDeckView, rendered only when `model.isOwner` (`deck.owner == ownerId`). Guest sees no Share/edit/delete affordances. **[FIX #3-iOS]** also ensure Restore/Rename/Delete are owner-gated.

### iOS test layers
- **swift test (PoseDeckCoreTests) — RUNS:** OfflineWritePath.grantGuest enqueues correct wire + optimistic row; **[FIX #6-iOS]** re-grant `(deck,user)` 400 → silent no-op. SyncEngine: **[FIX #4]** CREATE user==me + deck absent → `onGuestDeckNeedsHydration`; CREATE user==me + deck PRESENT → no hydration; CREATE user!=me (owner echo) → no hydration; **[FIX #7-iOS]** DELETE user==me + foreign owner → evict deck+cards+images; DELETE where I own deck → keep; DELETE + deck row absent → no-op. DeckGuestRepository.resolveUser builds filter+query. **[FIX #3-iOS]** backfill reconcile prunes a stale mirror guest; trashed-deck list excludes foreign-owned. Add all as regression tests per the gauntlet.
- **Live-PB integration (swift test) — RUNS:** owner grants guest by email → guest backfill sees deck; revoke evicts.
- **XCUITest — SKIP (simulator broken per memory; compile-only):** owner sees Share, guest does not; grant-by-email shows guest. Written but not run in this env.
- **Compile-check — RUNS:** `swift build` of PoseDeckCore + `xcodebuild build` of the app target (compile-only, no simulator run).

---

## RUN-vs-SKIP SUMMARY IN THIS ENV
- **RUNS:** Phase A migration apply + A2 integration suite (live dev PB, POSEDECK_DEV=true); all web component/unit/realtime/integration tests; iOS `swift test` core unit + live-PB integration; `swift build` + `xcodebuild build` compile-check.
- **SKIP:** iOS XCUITest (simulator broken — author tests, do not run); web Playwright E2E only if no Playwright harness present (otherwise run). Docker-gated steps if any (org-gated per memory).

## BUILD ORDER (sequenced)
1. Phase A (migration + A2 integration green) — establishes guest discovery + rule guarantees before clients.
2. Phase B (web; agent-full verifiable) — B1→B2→B3→B4→B5→B6, then web test layers green.
3. Phase C (iOS) — C1→C2→C3→C4→C5→C6→C7→C8, then `swift test` + compile-check green.
4. Run milestone-gauntlet (web) and milestone-gauntlet-ios per the established cadence; commit at each green checkpoint.

## CRITICAL DEVIATIONS FROM THE ORIGINAL DESIGN (do NOT revert)
- **Web mid-session grant fix (B4/FIX #1) is MANDATORY, not "only if e2e shows a gap"** — web deck list is Dexie-mirror-backed (verified DeckListPage:161→liveDecks), same as iOS.
- **Web mid-session revoke eviction (B4/FIX #2) is ADDED** — the original design omitted it entirely; web had no guest-side cascade-evict.
- **Trash owner-scoping (B1/C5/FIX #3) on BOTH platforms** — original design didn't gate guests out of an owner's trashed shared decks.
- **Duplicate-grant 400 as idempotent success (B2/C2/FIX #6)** — original relied on a racy client pre-check only.
- **deck_guests added to recentlyCreatedIds (B1/FIX #8)** — original's "pendingRecordIds already covers it" was incomplete.
- **Hydration self-share/already-present guard + strict foreign-owner eviction (FIX #4/#7)** — prevents pointless refetches and prevents an owner's own deck being evicted.

Relevant absolute paths: all listed under `/Users/qthienng/projects/pose-deck/backend/pb_migrations/`, `/Users/qthienng/projects/pose-deck/web/src/`, `/Users/qthienng/projects/pose-deck/ios/PoseDeckCore/Sources/PoseDeckCore/`, and `/Users/qthienng/projects/pose-deck/ios/PoseDeck/Sources/`.
