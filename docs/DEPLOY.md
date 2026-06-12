# Pose Deck — hosting on TrueNAS

Deploys the **PocketBase backend**, the **web frontend**, and (optionally) the
**anisette** server as one compose stack. Validated on TrueNAS SCALE with
**Nginx Proxy Manager (NPM)** in front.

## Networking model

Each service **publishes a host port** (`ports:`), and a reverse proxy you run
separately (NPM, Traefik, Caddy — here NPM on the same box) maps your domain to
`<host-ip>:<published-port>` and terminates TLS:

```
Internet → router (forward 443) → NPM → app.<domain> → <host-ip>:8080  (web)
                                       → api.<domain> → <host-ip>:8090  (PocketBase)
                                       → anisette.<domain> → <host-ip>:6969 (SideStore only)
```

There is **no shared external Docker network** — that model produced
`network reverse-proxy ... could not be found` and isn't needed when the proxy
routes by host IP:port.

| Service | Image | Host port (default) | Container port (fixed) |
|---|---|---|---|
| `posedeck-pb` (PocketBase) | `ghcr.io/muchobien/pocketbase` (pinned) | 8090 | 8090 |
| `posedeck-web` (nginx + SPA) | **built from `web/`** | 8080 | 80 |
| `posedeck-anisette` | `dadoum/anisette-v3-server` | 6969 | 6969 |

Change a **host** port (left side of `ports:`, via the `*_PORT` env vars) to
avoid clashes; the container side is fixed by the app.

> **Why build from source (not the GHCR image)?** The `web` GitHub Actions
> workflow pushes an image to GHCR, but it builds **without** a
> `VITE_API_BASE_URL` arg — so that image bakes in the `localhost` dev default
> and is a CI build-check, **not** a deployable artifact. `VITE_API_BASE_URL`
> must be known at build time, so you build with it set.

---

## A. Deploy from a checkout (CLI `docker compose`)

### 1. Get the source onto the host

```sh
# ideally onto a snapshotted dataset
git clone https://github.com/Neihtq/pose-deck.git /mnt/pool/pose-deck
cd /mnt/pool/pose-deck/backend
```

`pb_data/` (DB + uploaded photos) and `anisette/` (signing keychain) are created
here on first run — keep them on a dataset your snapshots cover. They are
gitignored.

### 2. Configure (`.env` beside the compose)

```sh
cp .env.example .env
# edit .env:
#   POSEDECK_API_URL = the PUBLIC https URL your proxy routes to PocketBase
#   (optional) POSEDECK_PB_PORT / POSEDECK_WEB_PORT / POSEDECK_ANISETTE_PORT
```

`VITE_API_BASE_URL` is baked into the web bundle at **build time** from
`POSEDECK_API_URL`. Changing it later means **rebuilding** the web image, not
just restarting.

### 3. Build and start

```sh
docker compose build web        # builds posedeck-web:local from ../web
docker compose up -d            # pb + web + anisette
docker compose ps               # all healthy/running
```

### 4. Wire the reverse proxy (NPM)

Create one Proxy Host per service. Forward Hostname/IP = the host's LAN IP;
Forward Port = the **published host port** (8090 / 8080 / 6969 by default);
request an SSL cert and force HTTPS:

| Public host | Forward to |
|---|---|
| `app.<domain>` | `<host-ip>:8080` |
| `api.<domain>` | `<host-ip>:8090` |
| `anisette.<domain>` | `<host-ip>:6969` (SideStore only) |

For **remote access**, forward router port **443** (and **80** for Let's Encrypt
challenges) to the NPM host. You do **not** forward 8090/8080/6969 — only NPM is
internet-facing.

---

## B. Deploy via the TrueNAS GUI ("Custom App", paste YAML)

The GUI can't read a `.env` and doesn't run from the repo directory, so two
adjustments to the committed compose are required when pasting:

1. **Make every volume path absolute** — and point PocketBase at the dirs under
   **`backend/`**, not the repo root:

   ```yaml
   volumes:
     - /mnt/pool/pose-deck/backend/pb_data:/pb_data
     - /mnt/pool/pose-deck/backend/pb_migrations:/pb_migrations:ro
   # anisette:
     - /mnt/pool/pose-deck/backend/anisette:/home/Alcoholic/.config/anisette-v3
   ```

   > ⚠️ **The #1 gotcha.** Mounting the repo *root* `pb_migrations` (which
   > doesn't exist — migrations live under `backend/`) gives PocketBase an empty
   > `/pb_migrations`, so **no collections are created**. Symptom: **login works**
   > (auth is built in) but **every deck-save and image-upload fails** with API
   > errors. Fix the path to `.../backend/pb_migrations` and redeploy.

2. **Inline literal values** for `${...}` (no `.env` in the GUI): replace
   `${POSEDECK_API_URL:?...}` with the actual URL, and the `${*_PORT:-...}`
   mappings with literal `"8090:8090"` etc.

3. **Building in the GUI is hit-or-miss.** If the Custom App won't run the
   `build:` block, build the image once on the NAS CLI and reference it by name
   instead:

   ```sh
   cd /mnt/pool/pose-deck/web
   docker build --build-arg VITE_API_BASE_URL=https://api.<domain> -t posedeck-web:local .
   ```

   ```yaml
   web:
     image: posedeck-web:local   # drop the whole build: block
   ```

Then wire NPM exactly as in **A.4**.

---

## First-run admin + a real user

1. Open the PocketBase admin at `http://<host-ip>:<pb-port>/_/` (or
   `https://api.<domain>/_/`) → create the superuser.
2. On first start, PocketBase applies `pb_migrations/` and creates the
   collections — confirm `decks`, `cards`, `card_images`, `deck_guests`,
   `card_completions` appear under **Collections**. `1700000008` (email lookup)
   and `1700000009` (guest back-relation — without it shared decks 404) are
   load-bearing for sharing. The dev-seed (`1700000010`) is gated on
   `POSEDECK_DEV`, unset here, so no seed data in prod.
3. Create your photographer user in the `users` collection (or enable signups),
   then sign in on the web app.

## iOS app

The phone uses the **same** PocketBase URL.

- **Same network (testing):** point the app at `http://<host-ip>:<pb-port>` via
  the sign-in screen's **"Use a different server"** field.
- **Remote / over the internet:** iOS requires **HTTPS**, so it must be the
  proxied `https://api.<domain>` (a raw public `ip:port` is plaintext and iOS
  blocks it). Enter that URL in the app, or bake it into
  `ios/PoseDeck/Config/Config.xcconfig` → `API_BASE_URL`.

SideStore signing uses the `anisette.` host — see `ios/SIDESTORE.md`. If you
install via Xcode instead, you can drop the anisette service entirely.

---

## Updating after a code change

```sh
cd /mnt/pool/pose-deck && git pull
cd backend
docker compose build web        # rebuild the SPA (if web/ or the API URL changed)
docker compose up -d            # recreate changed containers
```

PocketBase updates: bump the pinned tag in `docker-compose.yml`, then
`docker compose pull pocketbase && docker compose up -d`.

## Backups

Snapshot/replicate the `backend/pb_data/` (and `backend/anisette/`) datasets.
`pb_data/` holds the database **and** the uploaded reference photos; anisette
holds the signing keychain (losing it just means re-pairing SideStore).

## Troubleshooting

- **Login works but decks won't save / images won't upload** — the collections
  weren't created: `/pb_migrations` is mounted from the wrong path. Point it at
  `.../backend/pb_migrations` and redeploy.
- **`network reverse-proxy ... could not be found`** — you're using an old
  external-network compose; this stack publishes host ports instead and needs no
  such network. Use the current `docker-compose.yml`.
- **`required variable POSEDECK_API_URL is missing`** — no `backend/.env` (CLI),
  or you pasted `${...}` into the GUI without inlining a literal value.
- **Web calls the wrong backend** — `VITE_API_BASE_URL` is baked in at build
  time; rebuild the web image after changing it.
- **Port already in use** — change the host (left) side via `POSEDECK_*_PORT`.
- **iOS can't connect remotely** — it must be `https://` via the proxy, not a
  plaintext public `ip:port`.
