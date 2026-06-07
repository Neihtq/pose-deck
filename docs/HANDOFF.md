# Pose Deck — Developer Handoff (device-only & deploy items)

> Written 2026-06-07 after the autonomous M0–M8 build run. Everything the agent
> could build and verify is done and green; this lists the items that need a
> real device, an Apple ID, a deployed backend, or your sign-off.

## Build status

| Milestone | State |
|---|---|
| M0 backend · M1 web · M2 iOS prep · M3 sync · M4 shoot · M5 sharing · M6 PDF | ✅ done, gauntlet-passed, verified |
| M7 SideStore | 🟡 CI + manifest authored; **on-device install is yours** (below) |
| M8 polish | ✅ web a11y/error-states done; **end-to-end dry run is yours** (below) |

Verification reached here: web — full vitest + integration (live PB) + Playwright
e2e + build + a11y lint, all green. iOS — `swift test` (PoseDeckCore, 400+
tests) + app `xcodebuild` + the 17-test XCUITest suite on the iPhone 16 Pro
simulator, all green. The simulator works in this environment; a *physical
device* and Apple-ID signing do not, so those remain below.

## 1. iOS on physical device (M2/M4 feel + camera)

The XCUITests drive the app on the simulator via accessibility controls, but
**swipe physics, camera, and haptics are hand-verified only.** On a real iPhone:

- **Shoot mode (M4):** swipe-right=Done advances; swipe-left=Skip moves the card
  to the end and re-surfaces; swipe-up opens the full-image+notes detail; the
  persistent Undo reverses the last swipe; "Card N of M" + "+K skipped" update.
  Confirm the gesture thresholds/animation feel right (the CI hook buttons can't
  test feel).
- **Images:** in-app **camera** capture (simulator has no camera) → compress
  (1080/q0.8) → upload → thumbnail.
- **Offline (M3):** airplane-mode — create/edit a deck offline, confirm it
  persists across relaunch and drains to the server when back online.
- **BGAppRefresh pre-cache (M3):** a deck with a shoot date within 48h (or
  pinned "Download for offline") pre-caches deck+cards+image bytes in the
  background. Background-task firing is device-only.
- **Realtime cross-device (M3/M5):** edit on web, watch it appear on the phone
  with no manual refresh; share a deck → it appears on the guest's device;
  revoke → it disappears.
- **Keychain (M2):** session persists across relaunch; sign-out clears it AND
  (M4 gauntlet SEC fix) a second user sees none of the prior user's cached
  protected images.

## 2. M7 — SideStore distribution (device + Apple ID + anisette)

CI authoring is done (`.github/workflows/ios.yml` `archive-ipa` job,
`ios/exportOptions.plist`, `ios/apps.json`, `ios/update-apps-json.sh`). Full
walkthrough in **`ios/SIDESTORE.md`**. Your steps:

1. **Fill placeholders** in `ios/apps.json`: `<OWNER>`/`<REPO>` (your GitHub
   repo, used in the source/download/icon URLs) and commit an app icon PNG.
2. **Deploy anisette** (`dadoum/anisette-v3-server`, already in
   `backend/*compose*.yml`) and note its URL.
3. **Tag a release** (`git tag v0.1.0 && git push --tags`) → the CI job builds
   the unsigned IPA, regenerates `apps.json`, and publishes a GitHub Release.
   *(The archive/export step runs on GitHub's macOS runner; it's never been
   executed — validate the first run and adjust the unsigned-export path if
   `-exportArchive` refuses; the Payload/-zip fallback is already wired.)*
4. On the iPhone: install **SideStore**, set the anisette URL + your Apple ID,
   add the AltStore source URL, install Pose Deck, and refresh within 7 days.

## 3. Backend deploy (M-deploy — whenever ready)

Dev runs against a bare PocketBase binary; production is the compose stack in
`backend/docker-compose.yml` (ARCHITECTURE.md §9). Your steps: deploy to
TrueNAS, wire reverse-proxy routes (`app.` → web, `api.` → PocketBase,
`anisette.` → anisette) + TLS, ZFS snapshot/replication. **Apply all
`backend/pb_migrations/` on the prod instance** — note `1700000008`
(users email-lookup for sharing) and `1700000009` (the back-relation
guest-visibility fix; without it sharing 404s). Point the web app
(`VITE_API_BASE_URL`) + iOS app (`Config/Config.xcconfig` `API_BASE_URL`) at
`api.<domain>`. Docker is org-gated on this dev machine — build/push the web
image from CI (GHCR) or a machine with Docker access.

## 4. M8 — end-to-end dry run (your sign-off)

The real M8 acceptance: **prep a deck on web → shoot it on the phone → export a
PDF**, on deployed infra. Confirm the whole loop feels right on a real shoot
(the original problem this app solves). Web a11y + error states are done and
agent-verified; this dry run is the human judgment call.

## Notes / conventions for future work
- Dev creds + restart commands: `STATUS.md`. Milestone plans:
  `docs/plans/M{3,4,5}-*.md`. Process: `docs/PROJECT_PLAN.md` §0.
- iOS run requirements (the simulator works now): ad-hoc sign
  (`CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES`) or
  Keychain fails (-34018); unlink the HW keyboard or `typeText` hangs. Use
  `ios/PoseDeck/run-uitests.sh`. **Always re-run the XCUITests after iOS
  app-layer changes** — compile-only has missed three runtime bugs this run.
- The shared dev DB accumulates test decks from integration/XCUITest runs;
  clean to just "Sample Shoot (dev seed)" if row-not-found flakiness appears.
- Nothing has been pushed; all work is local commits on `main`.
