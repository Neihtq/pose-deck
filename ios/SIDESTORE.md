# Pose Deck — SideStore distribution (device-only handoff)

Pose Deck is installed via **SideStore** (an AltStore fork) instead of the App
Store. SideStore re-signs the app **on device** with a *free* Apple ID, using a
self-hosted **Anisette** server to satisfy Apple's authentication. No paid Apple
Developer account is required (ARCHITECTURE.md §9/§10, PROJECT_PLAN.md M7).

What CI produces (fully automated, see `.github/workflows/ios.yml`):

- an **unsigned** `PoseDeck.ipa` (workflow artifact on every main build; attached
  to a GitHub Release on `v*` tags),
- an updated **`ios/apps.json`** AltStore source manifest (attached to the
  Release on tags).

Everything below is 👤 **dev-only** — it needs a real iPhone + an Apple ID, so it
cannot be done in CI or by the agent.

---

## 0. One-time: fill in the placeholders

Before the source works, edit `ios/apps.json` and replace:

| Placeholder | Replace with |
|---|---|
| `<OWNER>` | your GitHub owner/org (e.g. `qthienng`) |
| `<REPO>`  | the repo name (e.g. `pose-deck`) |
| `iconURL` | URL of a real 1024px PNG app icon (commit one to e.g. `ios/PoseDeck/icon.png`) |

`version` / `versionDate` / `downloadURL` / `size` are rewritten automatically by
`ios/update-apps-json.sh` on each tagged release, so you can leave their initial
placeholder values alone.

---

## 1. Deploy the Anisette server (once, on the host)

The compose files already define it (`backend/compose.dev.yml`,
`backend/docker-compose.yml`) using `dadoum/anisette-v3-server`:

```bash
cd backend
docker compose -f compose.dev.yml up -d anisette   # local dev, :6969
# or, in production:
docker compose up -d anisette                       # behind the reverse proxy
```

- Local dev: reachable at `http://localhost:6969`.
- Production: exposed at `https://anisette.<your-domain>` via the reverse proxy
  (see `docker-compose.yml` / ARCHITECTURE.md §9). Persist
  `./anisette` (the keychain volume) so pairing survives restarts.

## 2. Install SideStore on the device (once)

Follow the official guide at <https://sidestore.io>. In short:

1. Install SideStore's own IPA via a pairing tool (e.g. Jitterbug / the
   SideStore web installer) and a WireGuard pairing file.
2. In **SideStore → Settings**, set the **Anisette server URL** to your server
   from step 1 (`https://anisette.<your-domain>` or the LAN `http://<host>:6969`).
3. Sign in with your **free Apple ID**. SideStore stores an app-specific session;
   the Apple ID is **never** committed anywhere — it lives only on the device.

## 3. Add the Pose Deck source

In SideStore: **Sources → + (Add Source)** and paste the manifest URL:

```
https://github.com/<OWNER>/<REPO>/releases/latest/download/apps.json
```

(This is the `sourceURL` in `apps.json`; `releases/latest/download/...` always
resolves to the newest tagged release's `apps.json`.)

## 4. Install / sign Pose Deck

1. Open the **Pose Deck** source in SideStore → tap **Pose Deck → Install**.
2. SideStore downloads the unsigned IPA (`downloadURL`), then **signs it on
   device** with your Apple ID (this is where Anisette is used) and installs it.
3. First launch: point the app at your PocketBase backend if needed (the dev
   build defaults to the `API_BASE_URL` baked in via `Config/Config.xcconfig`).

## 5. Refresh cadence (important)

Free-Apple-ID signing certificates **expire after 7 days**, and a free account
allows at most **3 sideloaded apps** at a time. To avoid the app dying:

- Open SideStore and **Refresh** Pose Deck **at least once a week** (SideStore can
  refresh in the background over Wi-Fi if it can reach your Anisette server, but
  treat the manual weekly refresh as the reliable path).
- When CI publishes a new `v*` tag, SideStore detects the bumped `version` in
  `apps.json` and offers an **Update** (which also re-signs for another 7 days).

## 6. Publishing a new build (dev workflow)

```bash
# bump MARKETING_VERSION in ios/PoseDeck/project.yml, commit, then:
git tag v0.1.1
git push origin v0.1.1
```

The `archive-ipa` job builds the unsigned IPA, runs `update-apps-json.sh`, and
attaches `PoseDeck.ipa` + `apps.json` to the `v0.1.1` Release. SideStore picks it
up on the next refresh.

---

## Placeholders a human must supply

- **GitHub `<OWNER>` / `<REPO>`** in `ios/apps.json` (used in `sourceURL`,
  `downloadURL`, `iconURL`).
- **App icon PNG** behind `iconURL`.
- **Apple ID** — entered only in SideStore on the device, for on-device signing.
- **Anisette server URL** — set in SideStore settings (your deployed server).
