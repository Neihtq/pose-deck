# M3 Sync — Implementation Plan (vetted via design+adversarial-review workflow 2026-06-07)

All key adversarial claims verified against real code:
- Locked model confirmed: `card_images` has only `{card, position, file, created}`, `deck_guests` `{deck, user, granted_at}` (no `updated`), `card_completions` uses `changed_at`. iOS models match.
- PB SDK auto-cancellation defaults ON (`enableAutoCancellation=!0`).
- CardEditor reads card via `getFirstListItem` (PB direct, line 133).
- Cross-origin premise holds: `VITE_API_BASE_URL` is absolute; nginx.conf has NO `/api` proxy block (only `/assets/`, `/`, `/index.html`).
- `dexie-react-hooks` not in package.json (web realtime design needs it).

I have enough to produce the consolidated plan. Here it is.

---

# M3 Sync — Consolidated Implementation Plan

All adversarial claims below were verified against the real code (types.ts locked model; PB SDK `enableAutoCancellation=!0`; CardEditor.tsx:133 `getFirstListItem`; nginx.conf has no `/api` proxy; `dexie-react-hooks` absent; iOS models confirm no `clientUpdatedAt` on CardImage/DeckGuest/CardCompletion).

## Cross-cutting invariants (apply everywhere, both clients)

1. **Idempotency / no-duplicate-on-lost-ack** — Use **client-supplied record ids** on create (PocketBase accepts a 15-char `id` on POST). Web mints a real PB-shaped id (15-char alphanumeric), NOT a `tmp_` id; iOS does the same. Result: create becomes idempotent — a retry after a lost 2xx hits the existing id and PB returns 400 "id already exists", which the processor **classifies as success** (fetch canonical, remove entry). This eliminates temp-id reconciliation entirely AND the duplicate-insert hole. `X-Idempotency-Key` header still sent for forward-compat but is not relied on. (Folds: web idempotency-precheck-broken, web inflight-resend-duplicates, iOS lost-2xx-duplicate, and collapses iOS/web temp-id remap to a no-op.)

2. **Temp-id reconciliation → eliminated** by invariant #1. Since client id == server id, there is no rewrite of child FKs or queued payloads. The only "reconcile" is merging server-canonical `created`/`updated` into the local row on 2xx. (Folds: web temp-id-404-navigate, web FK-remap, iOS fictional-temp-id-path.)

3. **LWW is per-entity, not uniform** — ordering key map:
   - `decks`, `cards` → `client_updated_at`
   - `card_completions` → `changed_at`
   - `card_images` → **no LWW**: create = insert-by-id, delete = hard remove-by-id; never overwrite a present local blob/row with an echo lacking bytes
   - `deck_guests` → **no LWW**: insert on create/update, hard remove on delete (revoke)
   - Empty-string clock does NOT auto-lose: if incoming clock is `""`, fall through to server `updated` (decks/cards) else apply. Ties → skip. (Folds: web invents-client_updated_at, web missing-updated-fallback, web empty-string-loses, iOS SyncRecord-assumes-field, iOS image-LWW-nonexistent-field.)

4. **Realtime self-echo suppression** — Keep a short-TTL "recently-confirmed" set keyed `(entity,id,clientClock)` populated by the outbox on 2xx. A realtime event matching an in-flight or just-confirmed mutation is skipped unconditionally (independent of timestamp math). Also: an entry being in-flight is keyed by the **server id** (== client id per #1), so the echo's id matches. (Folds: web realtime-create-duplicate-row, iOS echo-pending-guard-gone, iOS realtime-vs-outbox-race.)

5. **Image-token cache stability** — Protected file URLs carry a volatile `?token=`. Cache key (SW and any Dexie/blob key) strips `token`, preserves `thumb`. Token URLs are minted lazily at access (never cached as a key); blob/object URLs are owned by a dedicated component with revoke-on-unmount. (Folds: web token-thrash, web blob-URL-leak, web thumb-mismatch, iOS cached-blob-token-expiry.)

6. **Subscribe-before-resync ordering** — Open all 5 SSE subscriptions FIRST, then run the REST backfill; LWW/upsert idempotency makes the overlap safe. Same on reconnect. (Folds: web snapshot-then-subscribe-inversion.)

7. **Reconciling (not additive) resync** — Backfill fetches the server id-set per collection and **deletes local rows absent from it** (scoped to viewable records); critical for `card_images` hard-deletes. Also fetches must NOT be unfiltered for the trash case — pull `deleted_at != ''` correctly so trashed decks land in trash view, not main. (Folds: web unfiltered-resync, web hydrate-clobbers-pending; hydrate routes through the same LWW merge, never blind bulkPut.)

8. **Reorder atomicity** — One outbox entry per moved card, but on a 4xx drop of any one, **re-derive and re-enqueue a full consistent restripe** of the affected deck (not single-row revert). Partial intermediate order is tolerated only for the actor's own tabs. (Folds: web reorder-partial-order, iOS reorder-fanout.)

---

## Sequencing

Web first (fully agent-verifiable: unit + integration + e2e), then iOS core (swift-test verifiable), then iOS app (compile-only here).

---

### STEP 1 — Web foundation: ids, db v2, outbox primitives
Files: `web/src/lib/ids.ts` (new: `newClientId()` minting a 15-char PB-shaped id, `newIdempotencyKey()` — NO `tmp_` prefix per invariant #1), `web/src/lib/db.ts` (edit: v2 — add `status`/`next_attempt_at` to OutboxEntry, index `outbox: "++id, status, next_attempt_at, entity, recordId, idempotency_key"`; add `deck_guests` EntityTable + table `deck_guests: "id, deck, user, granted_at"` (NO `updated` index — field doesn't exist); add `_meta` for cursors; `card_images` index stays `"id, card, position"` — NO `updated`), `web/src/lib/outbox.ts` (new: enqueue/peekFifo/deleteEntry/bumpRetry/coalesce).
**Test (RUN):** unit (vitest + fake-indexeddb): id shape/guards, db v2 migration, outbox order==id-order, coalesce, peekFifo honoring next_attempt_at/status.

### STEP 2 — Web serverEntities + syncEngine
Files: `web/src/lib/serverEntities.ts` (new: per-entity discriminated payload union — only decks/cards carry `client_updated_at`+`deleted_at`; card_images create+hard-delete only; encode/decode; `send()` passes **`requestKey: entry.idempotency_key`** to defeat SDK auto-cancellation AND `pb.autoCancellation(false)` at engine start; classify 400-duplicate-id-on-create as success; rollback for 4xx), `web/src/lib/syncEngine.ts` (new: single-flight FIFO drain, `isAbort`→transient-no-retry-count, 2xx delete+merge-canonical, 4xx drop+rollback+toast, 401 pause, 429/5xx backoff preserving head-of-line; Web Locks single-drainer + BroadcastChannel where every engine wakes the lock-holder on enqueue; recently-confirmed set for invariant #4).
**Test (RUN):** unit with mock PB sender: 2xx, 4xx rollback, 5xx backoff head-of-line, `isAbort` classification, 400-dup-id→success, offline idle, injected-clock backoff.

### STEP 3 — Web localStore + live read layer
Decision: add **`dexie-react-hooks@^1.1.7`** to package.json (folds web missing-dep; it's the official dexie@4 companion). Files: `web/src/lib/localStore.ts` (new: liveDecks/liveTrashedDecks/liveDeck/liveCards/liveCardImages re-expressing PB filters; LWW `mergeRecord` helper shared by reconcile + realtime + hydrate; `hydrateFromServer` routed through `mergeRecord`; `clearLocalStore`), `web/src/lib/useLiveQuery.ts` (new: thin `useSyncExternalStore` wrapper — or use dexie-react-hooks directly).
**Test (RUN):** unit: localStore queries match PB filter contract; mergeRecord LWW truth table (per-entity keys, empty-string fallback, ties); hydrate-preserves-pending.

### STEP 4 — Web realtime manager
Files: `web/src/sync/realtimeManager.ts` (new: subscribe 5 collections FIRST then resyncAll per invariant #6; epoch-guard the async start() so a mid-start signout can't leak subscriptions — re-check `started` after each await, await unsub in stop; reconciling resync per #7), `web/src/sync/mergeEvent.ts`+`lww.ts` (fold into localStore.mergeRecord or keep thin), self-echo guard reads recently-confirmed set.
**Test (RUN):** unit: start subscribes to exactly 5; stop unsubscribes; idempotent double-start; reconnect resyncs; delete-vs-soft-delete; cascade-delete tolerance.

### STEP 5 — Web API wrappers + page rewire
Files: `deckApi.ts`/`cardApi.ts` (edit: write Dexie + enqueue, same signatures; reorder per invariant #8; `nextPosition` from Dexie not network), `imageApi.ts` (edit: keep upload AND delete **both PB-direct synchronous** per option A consistency — fold web image-delete-inconsistency; mirror result into Dexie), `CardEditor.tsx` (edit: **read card via `liveQuery`/Dexie not `getFirstListItem`** — fold web create-navigate-404; add `useTempIdRedirect`-style guard is now unnecessary since id is stable, but still read from Dexie), `DeckListPage.tsx`/`DeckDetailPage.tsx` (edit: useLiveQuery, drop refresh/reorder-catch), `main.tsx`/`AuthContext.tsx` (edit: start/stop engine + realtime, hydrate on signin, clearLocalStore on signout).
**Test (RUN):** unit: each mutation enqueues one (coalesced) entry, reorder only moved cards, CardEditor reads Dexie.

### STEP 6 — Web service worker (DECISION REQUIRED, then build)
**Blocking decision folded in:** cross-origin premise is real (verified: nginx has no `/api` proxy, VITE base is absolute). **Chosen path: drop SW caching of files/API entirely; precache only the static app shell; the Dexie explicit-pin is the SOLE offline-image mechanism.** (This avoids opaque cross-origin responses and quota blowup; folds the critical cross-origin issue without an infra change.) Files: `vite.config.ts`+`package.json` (VitePWA injectManifest devDeps), `src/sw.ts` (precache shell + SPA nav fallback + NetworkOnly for everything API/auth; NO file/API runtime cache), `src/sw-routes.ts` (pure predicates), `registerSW.ts`, `main.tsx`, `vite-env.d.ts`. Dexie pin tables: `image_blobs` (key = `${collectionName}/${recordId}/${filename}`, token stripped), `pinned_decks`. Files `offlineKeys.ts`, `offlineImages.ts` (resolver returns `{url, release}` handle, not raw blob URL — fold leak issue), `pinDeck.ts` (routes mirror writes through `mergeRecord` LWW not blind bulkPut — fold pin-clobbers-pending; reconciling refresh deletes orphaned blobs — fold stale-content; counter derived from `image_blobs.count()` not in-memory increment), `<OfflineImage>` component owning createObjectURL/revoke, `useOfflinePin.ts`, `useOnlineStatus.ts`, `OfflineToggle.tsx`. AuthContext purge: keep `clearAuthOnUnauthorized` **synchronous**; trigger async purge via `authStore.onChange`; gate sign-IN of a different user on purge completion (fold async-401-leak-window).
**Test (RUN):** unit: sw-routes predicates, offlineKeys, offlineImages fallback+revoke, pinDeck transitions/resume/LWW-merge. **(SCAFFOLD/SKIP):** SW production-build + DevTools manual checks — replace with a Playwright e2e (`npm run build && preview`) asserting sw registers, no POST/auth cached, pin→offline render. E2e runs if Playwright browsers are installed in this env; otherwise scaffolded and SKIPPED with a note.

### STEP 7 — Web milestone gauntlet
Run `/milestone-gauntlet`. **(RUN):** unit (vitest), integration (live PB via `test:integration` — agent owns per verification-ownership). **(RUN if browsers present, else SKIP):** Playwright e2e. Commit at green.

---

### STEP 8 — iOS core: LocalStore + MutationSender + OutboxProcessor
Files under `ios/PoseDeckCore/Sources/PoseDeckCore/Sync/`: `LocalStore.swift` (protocol + InMemoryLocalStore; `SyncRecord.orderingTimestamp` is **per-conformance**: Deck/Card→clientUpdatedAt, CardCompletion→changedAt, CardImage/DeckGuest→nil meaning always-apply create/delete — fold iOS field-assumption), `MutationSender.swift` (raw Data dispatch; 401→distinct `.authExpired` not generic transient — fold token-expiry-retry-forever; 400-duplicate-id-on-create→`.success` — fold lost-2xx; `requestKey`/idempotency header), `OutboxProcessor.swift` (FIFO; **do NOT sleep inside the actor** — return `.deferred` and let external scheduler re-invoke after delay — fold actor-stall; causal-chain blocking only — skip-and-continue past independent entries; reorder as single logical unit — fold reorder-fanout; backoff via injected SyncClock).
**Note:** the offline-first **repo rewrite is in-scope** (creates mint client id, write LocalStore, enqueue) — fold iOS fictional-write-path. Position computed from LocalStore; processor may re-resolve append position at drain (fold offline-create-position).
**Test (RUN):** `swift test`: MutationSender classification incl. 401→authExpired + 400-dup→success; OutboxProcessor FIFO/2xx/4xx/backoff/maxRetries/single-flight; reorder-unit partial-fail→valid total order.

### STEP 9 — iOS core: RealtimeClient (SSE) + SyncEngine
Files: `RealtimeClient.swift` (pure SSEParser + injectable SSETransport; `URLSessionSSETransport` gated behind Darwin availability with a `URLSessionDataDelegate` fallback for Linux — fold bytes(for:)-Linux-build; PB_CONNECT→setSubscriptions→reconnect/resubscribe; surface auth-failed so engine refreshes token — fold dead-token-reconnect-loop), `SyncEngine.swift` (LWW per invariant #3; self-echo suppression per #4; subscribe-before-resync per #6; per-entity delete: decks/cards soft, images/guests hard — fold iOS hard-delete-images; deck soft-delete cascades to hide/evict children — fold cascade-orphans). **Replace** legacy `subscribe(collection:)` rather than keep it permanently throwing (fold dead-API); rewrite `APIClientSubscribeTests` to the positive path.
**Test (RUN):** `swift test`: SSEParser edge cases; SyncEngineLWW per-collection (incl. self-echo skip, image create/delete, guest revoke); RealtimeClient reconnect/resubscribe/stop. **(RUN, gated):** live-PB integration if `POSEDECK_INTEGRATION=1` and a PB server is reachable — else SKIP.

### STEP 10 — iOS app: SwiftData mirror + coordinator + pre-cache (COMPILE-ONLY here)
Files under `ios/PoseDeck/Sources/Sync/`: `LocalModels.swift` (@Model; LocalCardImage has blob+blobETag, NO clientUpdatedAt; per-entity delete semantics), `LocalStore.swift`, `SwiftDataOutbox.swift` (bounded/aged consumed-keys store — fold unbounded-seenKeys), `MirrorRepositories.swift`, `SyncCoordinator.swift` (onSignedOut **awaits processor quiesce before purge**; warn on unsynced entries — fold signout-data-loss), `PrecacheService.swift`, `BackgroundRefresh.swift` (task id as single shared constant + DEBUG launch assertion it's in Info.plist — fold BGTask-crash). Pure helpers in Core: `LocalMirrorMapping.swift`, `PrecachePlan.swift`, `OutboxRefRemap.swift`. **Required VM edits (fold "VMs unchanged" is false):** change `CardEditorViewModel.repository` to `CardRepositoring` protocol type; edit `CardEditorHost`/`RootView` to inject Mirror repos and drop raw apiClient. project.yml: UIBackgroundModes + BGTaskSchedulerPermittedIdentifiers. Realtime scope: explicitly **defer deck_guests/card_completions realtime to M4/M5** OR add LocalDeckGuest + revoke-purge — state the deferral in the scope boundary (fold dropped-subscriptions). MirrorChangeTicker: **required debounce** 250–500ms (fold refresh-stampede).
**Test (RUN):** `swift test` on Core pure helpers: MirrorMerge, PrecachePlan (48h boundary/exclusions/pinned union), OutboxRefRemap (now near-trivial given stable ids). **(COMPILE-ONLY here):** `xcodebuild build` of PoseDeck scheme validates @Model schema, container wiring, BGTask glue, project.yml keys. **(SKIP — device-only):** SwiftData persistence, BGAppRefresh firing, SSE-over-wire, manual offline pass.

### STEP 11 — iOS milestone gauntlet + commit
Run `/milestone-gauntlet-ios`. **(RUN):** core `swift test` + xcodebuild build green. **(RUN gated / else SKIP):** live-PB integration. **(SKIP):** device manual pass — documented as deferred. Commit at green.

---

## Test-layer matrix in THIS environment

| Layer | Web | iOS core | iOS app |
|---|---|---|---|
| Unit | RUN (vitest + fake-indexeddb) | RUN (`swift test`) | RUN (Core pure helpers only) |
| Integration (live PB) | RUN (`test:integration`, agent owns) | RUN if PB reachable, else SKIP | n/a |
| E2E | Playwright: RUN if browsers installed, else SCAFFOLD+SKIP | n/a | n/a |
| Compile/build | RUN (`tsc -b && vite build`) | RUN (`swift build`) | RUN (`xcodebuild build`, compile-only) |
| Device/manual | SKIP (SW prod-build manual checks → converted to e2e where possible) | n/a | SKIP (simulator broken; SwiftData/BGTask/SSE-wire device-only) |

## Folded-fix ledger (all critical + major)
- **Web outbox:** locked-model field violation → per-entity payloads; SDK auto-cancel → `pb.autoCancellation(false)`+`requestKey`+isAbort handling; idempotency precheck broken & inflight-resend-dup → client-supplied stable ids + 400-dup-as-success; create-navigate-404 → CardEditor reads Dexie + stable id; reorder partial → full restripe re-enqueue; hydrate clobbers pending → mergeRecord LWW; image-delete inconsistency → both PB-direct.
- **Web realtime:** snapshot-then-subscribe → subscribe-first; missing-`updated` fallback & empty-string-loses → per-entity keys + server-`updated` fallback; unfiltered-resync resurrection & no-hard-delete-prune → reconciling resync; temp-id duplicate row → stable id + self-echo set; async-start leak → epoch guard; missing dep → add dexie-react-hooks.
- **Web SW:** cross-origin false premise → drop SW file/API caching, Dexie-pin is sole guarantee; blob leak → `<OfflineImage>` handle; thumb mismatch → consistent key strategy + document full-res for PDF; async-401 leak → sync clearAuth + onChange purge + sign-in gate; pin clobbers pending → mergeRecord; stale content → reconciling refresh.
- **iOS core:** field-assumption & image-LWW → per-conformance orderingTimestamp + image create/delete; fictional write-path → in-scope repo rewrite; lost-2xx-dup → stable id + 400-as-success; actor-stall → no in-actor sleep + causal-chain blocking; echo race → self-echo set keyed by server id; 401-retry-forever & dead-token-SSE → `.authExpired` + refresh seam; reorder fan-out → single logical unit; cascade soft-delete → hide/evict children; bytes(for:)-Linux → availability gate + delegate fallback; dead legacy API → replace.
- **iOS app:** "VMs unchanged" false → CardEditorViewModel→protocol + Host/RootView edits; image LWW/hard-delete → per-entity; reorder semantics → single unit; offline-create position → drain-time resolve; cached-blob token expiry → source-tagged URL; cascade orphans → child eviction; dropped subscriptions → explicit M4/M5 deferral; signout data-loss → await quiesce; BGTask crash → shared const + DEBUG assert; unbounded seenKeys → aged store; refresh stampede → required debounce.

**Open decisions to confirm before coding:** (1) SW path = "drop file/API SW caching, Dexie-pin only" (chosen, avoids infra change); if a same-origin `/api` proxy is preferred instead, that requires editing nginx.conf + VITE base — flag for sign-off. (2) iOS deck_guests/card_completions realtime deferred to M4/M5 (chosen) vs. add LocalDeckGuest now. (3) Client-supplied PB ids confirmed acceptable (PocketBase allows 15-char client id on create — removes idempotency hole without a Go hook).

Relevant files verified: `/Users/qthienng/projects/pose-deck/web/src/lib/types.ts`, `db.ts`, `pocketbase.ts`, `web/src/features/cards/CardEditor.tsx` (line 133 `getFirstListItem`), `web/nginx.conf` (no `/api` proxy), `web/package.json` (no dexie-react-hooks), `ios/PoseDeckCore/Sources/PoseDeckCore/Models/{CardImage,DeckGuest,CardCompletion,Deck,Card}.swift`.
