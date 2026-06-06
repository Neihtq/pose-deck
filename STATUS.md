# Pose Deck — Build Status & Resume Point

> Living scratchpad for picking up across sessions/reboots. Last updated: 2026-06-06.
> Authoritative plan: `docs/PROJECT_PLAN.md`. Spec: `docs/DESIGN.md`, `docs/ARCHITECTURE.md`.

## Where we are

| Milestone | Status |
|---|---|
| **M0** — backend foundation | ✅ done (PocketBase, 6 collections, migrations, seed, compose) |
| **M1** — web prep MVP | ✅ done + gauntlet passed (auth, deck/card CRUD, images, dnd reorder, dark mode, inline card delete) |
| **M2** — iOS prep MVP | ✅ **build + gauntlet passed (compile-verified)** — ⚠️ NOT yet run on device/simulator |
| **M3** — sync layer (outbox + realtime + offline) | ⬜ next |
| M4 shoot mode (iOS) · M5 sharing · M6 PDF · M7 SideStore · M8 polish | ⬜ pending |

Working tree clean, all on `main`, nothing pushed (push only when asked).
Latest commit: `4fca45c M2 gauntlet: 13 adversarial fixes + test layers`.

## ⏸️ Why we stopped: simulator reboot

The iOS Simulator runtime is wedged (`liblaunch_sim.dylib could not be opened`). The
runtime IS mounted and the dylib IS on disk; the `CoreSimulatorService` XPC layer is
stuck. `-runFirstLaunch` + `killall` did not clear it. **A full reboot is the remaining
fix.** User is rebooting.

### → FIRST THING after reboot
1. Verify the simulator boots:
   ```
   xcrun simctl boot "iPhone 16 Pro" && xcrun simctl list devices | grep "iPhone 16 Pro"
   ```
   If still `unavailable`, run `sudo xcodebuild -runFirstLaunch` then retry boot.
2. If it boots → **run the M2 app and do the on-device verification below** (this is the
   main unfinished M2 task), then M2 is fully done.
3. If it still won't boot → proceed to M3; iOS stays compile-only (acceptable, documented).

## M2 on-device checklist (👤 — the only thing left for M2)

Build: `cd ios/PoseDeck && xcodegen generate && open PoseDeck.xcodeproj`
(`.xcodeproj` is gitignored — regenerate with xcodegen.)
Sign in with `owner@posedeck.test` / `changeme123` (backend must be running — see below).

- [ ] Sign in; session persists across relaunch (Keychain)
- [ ] Deck list: grouping (Upcoming/Undated/Past), search, create, rename, duplicate, delete→trash→restore
- [ ] Deck detail: drag-to-reorder persists; swipe-to-delete a card inline (no need to open it)
- [ ] Card editor: title ≤60 counter, all fields save
- [ ] Images: PhotosPicker → compress (1080/q80) → upload → thumbnail renders; 5-image cap

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
