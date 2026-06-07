# On-device testing (split setup)

Test the iOS app on a physical iPhone while the backend keeps running on the
**dev Mac**. Three roles, one Wi-Fi network:

| Machine | Role |
|---|---|
| **Dev Mac** (`192.168.68.55`) | Runs PocketBase backend at `:8090` |
| **Build Mac** | Runs Xcode to sign + install the app onto the iPhone |
| **iPhone** | Runs the app; talks directly to the dev Mac's backend |

The app talks to the **backend**, not to the machine that built it — so the build
Mac never needs the backend, and the IP baked into the app must point at the dev
Mac running PocketBase.

> **All three devices must be on the same Wi-Fi.** The phone reaches the backend
> over the LAN; there's no tunnel.

## 1. On the dev Mac — run the backend bound to the LAN

```sh
cd backend
POSEDECK_DEV=true ./pocketbase serve --http=0.0.0.0:8090
```

`0.0.0.0` (not `127.0.0.1`) is what makes it reachable from the phone. Verify
from another device on the network: `curl http://192.168.68.55:8090/api/health`
→ `200`. Allow the macOS firewall prompt for `pocketbase` if it appears.

`POSEDECK_DEV=true` seeds the dev users: `owner@posedeck.test` / `changeme123`
(and `guest@posedeck.test` / `changeme123`).

**If the dev Mac's IP changes** (DHCP): find it with `ipconfig getifaddr en0`,
update `API_BASE_URL` in `ios/PoseDeck/Config/Config.xcconfig`, and rebuild.

## 2. On the build Mac — sign & install

```sh
git clone https://github.com/Neihtq/pose-deck.git
cd pose-deck/ios/PoseDeck
xcodegen generate          # brew install xcodegen first
open PoseDeck.xcodeproj
```

The committed `API_BASE_URL` already points at `192.168.68.55:8090`, so no edit
is needed as long as that's the dev Mac's IP.

In Xcode:
1. **PoseDeck** target → **Signing & Capabilities**
2. Check **Automatically manage signing**
3. **Team** → **Add an Account…** → your Apple ID (free; no paid program needed)
   → pick your **Personal Team**
4. If the bundle id `dev.posedeck.app` conflicts, make it unique
   (e.g. `dev.posedeck.app.<you>`)
5. Plug in the iPhone via USB (tap **Trust** on the phone), select it in the
   device dropdown, press **▶ Run** (Cmd-R)
6. First launch only: **Settings → General → VPN & Device Management →
   [your Apple ID] → Trust**

## Caveats (free Apple ID)

- **7-day expiry** — free-signed apps stop launching after 7 days. Re-run from
  Xcode to refresh. (SideStore / M7 is the eventual fix — see `SIDESTORE.md`.)
- **Background pre-cache (BGTask)** — the free personal team may reject the
  background-modes entitlement. If signing complains, drop it; foreground use is
  unaffected.
- **No camera in this path is fine** — that's a simulator limitation; a real
  device has the camera. Use it freely.

## ATS / cleartext HTTP

Already handled: `Config/Info.plist` sets `NSAllowsLocalNetworking`, which permits
plaintext HTTP to `192.168.x.x` LAN addresses without an exception per host.
