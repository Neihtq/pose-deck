# Pose Deck — Build Status & Resume Point

> Living scratchpad for picking up across sessions/reboots. Last updated: 2026-06-07.
> Authoritative plan: `docs/PROJECT_PLAN.md`. Spec: `docs/DESIGN.md`, `docs/ARCHITECTURE.md`.

## Where we are

| Milestone | Status |
|---|---|
| **M0** — backend foundation | ✅ done (PocketBase, 6 collections, migrations, seed, compose) |
| **M1** — web prep MVP | ✅ done + gauntlet passed |
| **M2** — iOS prep MVP | ✅ **DONE + simulator-verified** — 14 XCUITests green on iPhone 16 Pro |
| **M3** — sync layer (outbox + realtime + offline) | ✅ **DONE + both gauntlets passed + sim-verified** — web 242 tests/4 layers/9 fixes; iOS core 290 tests; iOS app 12 fixes; SwiftData crash found+fixed by re-running the 14 XCUITests (all green) |
| **M4** — iOS shoot mode | ✅ **DONE + gauntlet + sim-verified** (15/15 XCUITests; app raised to Swift 6 lang mode) |
| **M5** — sharing (deck_guests) | ✅ **DONE + both gauntlets** — grant/revoke by email + realtime; gauntlet caught a real sharing-breaking rule bug (back-relation migration 1700000009) |
| **M6** — PDF export (web) | ✅ **DONE** (@react-pdf/renderer; built early in parallel w/ M4) |
| **M7** — SideStore distribution | ✅ CI archive job + apps.json + exportOptions + SIDESTORE.md authored; **on-device install = 👤** (docs/HANDOFF.md) |
| **M8** — polish + dry run | ✅ web a11y + error states done (334 tests); **end-to-end device dry run = 👤** (docs/HANDOFF.md) |

**All agent-buildable work for M0–M8 is complete and verified.** Remaining work
is device-only / deploy / sign-off — see `docs/HANDOFF.md`.

Working tree clean, all on `main`, nothing pushed (push only when asked).
Latest commit: `4b77882 M3 iOS: fix SwiftData @Model crash + verify on sim`.

## M3 sync — what shipped (done 2026-06-07)
Local-first outbox + realtime + offline, both clients (ARCHITECTURE.md §4).
Vetted design + folded adversarial fixes in `docs/plans/M3-sync-implementation-plan.md`.
- **Web** (`web/src/lib/{ids,outbox,serverEntities,syncEngine,localStore}.ts`,
  `web/src/sync/`, `web/src/features/offline/`): client-supplied PB ids
  (idempotent create), Dexie outbox FIFO + backoff, realtime LWW merge,
  service-worker shell + Dexie offline pin. Reads via dexie-react-hooks
  useLiveQuery. All 4 test layers green.
- **iOS core** (`PoseDeckCore/Sources/PoseDeckCore/Sync/`): OutboxProcessor
  (no in-actor sleep), MutationSender, SSE RealtimeClient, SyncEngine (LWW +
  self-echo), OfflineWritePath, PrecachePlan. swift test 290.
- **iOS app** (`PoseDeck/Sources/Sync/`): SwiftData @Model mirror,
  SwiftDataOutbox, MirrorRepositories, SyncCoordinator, PrecacheService,
  BackgroundRefresh, MirrorChangeTicker (reactive re-query). Compile + the 14
  XCUITests verify it at runtime.
- **Key lesson**: compile-only ≠ runtime. A SwiftData `@Model` named its field
  `entity` (collides with NSManagedObject.entity) → decode SIGABRT only at
  runtime. Caught by re-running the M2 XCUITest suite against the M3 app.
  ALWAYS run the XCUITests after iOS app-layer changes now that the sim works.
- **Deferred to M4/M5**: deck_guests + card_completions realtime *consumption*
  (events flow into the store; no UI wiring yet). Offline image *upload*
  queueing (uploads still need network; deletes are queued).
- **On-device still dev-verified** (sim can't do): BGAppRefresh firing, real
  airplane-mode persist-across-relaunch, SSE-over-wire propagation, photo
  picker feel. See the iOS gauntlet report §4 for the full device checklist.

## ✅ Simulator fixed + M2 verified

The simulator XPC wedge cleared after the reboot. M2 on-device verification is now an
**automated XCUITest suite** (`ios/PoseDeck/UITests/`), not a manual checklist:

- **14 UITests green** on iPhone 16 Pro against the live PocketBase dev backend.
- Run with `ios/PoseDeck/run-uitests.sh` (whole suite) or `run-uitests.sh AuthUITests`
  (one class). It handles the signing/keyboard/photo-seed setup automatically.
- Coverage: sign-in + session persistence + sign-out (`AuthUITests`); deck
  create/grouping/search/rename/duplicate/delete→trash→restore (`DeckListUITests`);
  card add/title-60-cap/swipe-delete/drag-reorder-persists (`CardUITests`); image
  pick→compress→upload→thumbnail (`ImageUploadUITests`).

### Hard-won gotchas baked into the suite/script (read before touching UITests)
1. **Ad-hoc signing is required.** `CODE_SIGNING_ALLOWED=NO` strips entitlements, so
   Keychain writes fail with `errSecMissingEntitlement (-34018)` and sign-in silently
   fails. We added `Config/PoseDeck.entitlements` (keychain-access-group) and build/run
   with `CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES`.
2. **Unlink the Simulator hardware keyboard** (`defaults write com.apple.iphonesimulator
   ConnectHardwareKeyboard -bool false` + reboot) or `typeText` hangs forever.
3. **Search-scope row lookups.** The grouped List is lazy — off-screen cells aren't in
   the AX tree. Helpers create/find decks via the search field so the row is on-screen.
4. **Toggle taps need the trailing edge**; full-row tap hits the label. Reorder needs
   `press(forDuration:thenDragTo:withVelocity:.slow,thenHoldForDuration:)`.
5. `-uitest-reset` launch arg clears the keychain session for a clean start.

Dev DB note: a cleanup pass deleted 36 accumulated test-fixture decks; only the
"Sample Shoot (dev seed)" deck remains. Tests self-clean (trash their decks) but the
shared dev DB can still drift — re-clean if row-not-found flakiness returns.

## Restart the dev environment (these processes die on reboot)

Backend (bare PocketBase binary — Docker is org-gated, not used for dev):
```
cd /Users/qthienng/projects/pose-deck/backend
POSEDECK_DEV=true ./pocketbase serve --http=127.0.0.1:8090
```
Web dev server:
```
cd /Users/qthienng/projects/pose-deck/web
VITE_API_BASE_URL=http://127.0.0.1:8090 npm run dev    # http://localhost:5173
```
Verify backend up: `curl -s http://127.0.0.1:8090/api/health`

### Credentials
- App users (web + iOS): `owner@posedeck.test` / `changeme123`, `guest@posedeck.test` / `changeme123`
- PocketBase admin (http://127.0.0.1:8090/_/): `q.thien.nguyen@outlook.de` / `AsdfgHjkl95!`

## How we work (process — see also memory files)

- **Milestone gauntlet is mandatory DoD**: build → adversarial review (hostile lenses →
  independent refuters) → auto-fix EVERY confirmed finding + regression test → test layers
  → re-verify green. Workflows: `.claude/workflows/milestone-gauntlet.js` (web),
  `milestone-gauntlet-ios.js` (iOS). Invoke via `Workflow({scriptPath: ...})` (named
  registry may need a session to pick them up).
- **Commit cadence**: commit at every stable GREEN checkpoint within a milestone, not just
  at the end. Per-component commits. Never push unless asked.
- **Always independently re-verify** workflow output (re-run tests/builds, spot-check
  risky auto-fixes) — don't rubber-stamp. M1 caught a wrong auto-fix this way (title cap
  60 vs 200: DESIGN.md governs UI limits, ARCHITECTURE.md governs the data model).
- **Verification ownership**: web + backend fully agent-verifiable here; iOS is
  compile + `swift test` only until the simulator works (then agent can run it too).

## Test/build commands

- Web: `cd web && npm run build && npm run test && npm run lint`
  (integration: `npm run test:integration`; e2e: `npm run test:e2e`)
- iOS core: `cd ios/PoseDeckCore && swift test` (149 tests; +8 live-PB integration behind
  `POSEDECK_INTEGRATION=1`, needs backend running)
- iOS app compile: `cd ios/PoseDeck && xcodegen generate && xcodebuild -project PoseDeck.xcodeproj -scheme PoseDeck -destination 'generic/platform=iOS' build CODE_SIGNING_ALLOWED=NO`

## M3 preview (next milestone)

Outbox sync + realtime + offline pre-cache, both clients. Deferred items that land here:
reorder batching, file-token caching (~90s TTL like web), and the realtime `subscribe()`
stub in `ios/PoseDeckCore/.../APIClient.swift` (currently throws `notImplemented`).
Run it as a workflow + the appropriate gauntlet, in ultracode mode (user's default).
