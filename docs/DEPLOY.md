# Pose Deck — hosting on TrueNAS (Finch / build-from-source)

This deploys the **web frontend**, the **PocketBase backend**, and the
**anisette** server (for SideStore signing) as one compose stack, behind your
existing reverse proxy. The web image is **built from source on the host** — no
container registry and no image transfer from your Mac are required.

> **Finch note.** Everything here uses `docker compose`. If you build/validate
> on a Mac with [Finch](https://github.com/runfinch/finch) instead of Docker,
> the commands are identical with `finch compose` / `finch build` — Finch is a
> drop-in. On TrueNAS itself you'll typically use the built-in Docker/`docker
> compose`. The stack has been validated end-to-end with Finch (web image
> builds, serves 200, SPA deep-links fall back to `index.html`, and the API URL
> is correctly baked into the bundle).

The authoritative topology is **ARCHITECTURE.md §9**; this is the runbook.

---

## What runs

| Service | Image | Port (in-network) | Reverse-proxy host |
|---|---|---|---|
| `posedeck-pb` (PocketBase) | `ghcr.io/muchobien/pocketbase` (pinned) | 8090 | `api.shotdeck.<domain>` |
| `posedeck-web` (nginx + SPA) | **built from `web/`** | 80 | `app.shotdeck.<domain>` |
| `posedeck-anisette` | `dadoum/anisette-v3-server` | 6969 | `anisette.shotdeck.<domain>` |

All three only **expose** their ports to the external `reverse-proxy` Docker
network — they never publish to the host. Your proxy terminates TLS and routes
by hostname.

---

## 1. Prerequisites on the host

- A reverse proxy (Traefik / Nginx Proxy Manager / Caddy) already running and
  attached to a Docker network named **`reverse-proxy`** (the stack joins it as
  an `external` network). If yours has a different name, change it at the bottom
  of `backend/docker-compose.yml`.
- Three DNS records / proxy hosts pointing at the proxy:
  `app.`, `api.`, `anisette.` `shotdeck.<your-domain>`.
- Docker + `docker compose` (TrueNAS SCALE ships these; or Finch on a Mac).

## 2. Get the source onto the host

Because the web image builds from source, the stack runs from a full checkout
(the compose file's build context is the sibling `../web` directory):

```sh
# On TrueNAS, ideally onto a ZFS dataset, e.g. /mnt/tank/shotdeck
git clone https://github.com/Neihtq/pose-deck.git /mnt/tank/shotdeck
cd /mnt/tank/shotdeck/backend
```

`pb_data/` (PocketBase data + uploads) and `anisette/` (signing keychain) are
created here on first run — keep them on the ZFS dataset so snapshots/replication
cover them. They are gitignored.

## 3. Configure the API URL (baked into the web bundle)

`VITE_API_BASE_URL` is a **build-time** value compiled into the static bundle,
so the web app needs to know the public PocketBase URL *before* it's built.

```sh
cp .env.example .env
# edit .env → POSEDECK_API_URL=https://api.shotdeck.<your-domain>
```

> Changing `POSEDECK_API_URL` later means **rebuilding** the web image
> (`docker compose build web`), not just restarting it.

## 4. Apply backend migrations note

All migrations in `backend/pb_migrations/` apply automatically on PocketBase
start. Two are load-bearing for sharing — confirm they're present in the
checkout (they are committed):

- `1700000008_*` — users email-lookup for sharing.
- `1700000009_*` — guest-visibility back-relation fix (**without it, shared
  decks 404**).

The dev-seed migration is gated on `POSEDECK_DEV`, which this prod stack does
**not** set, so no seed users/decks are created in production.

## 5. Build and start

```sh
cd /mnt/tank/shotdeck/backend
docker compose build web        # builds posedeck-web:local from ../web
docker compose up -d            # starts pb + web + anisette
docker compose ps               # all healthy/running
```

(With Finch: `finch compose build web` / `finch compose up -d`. Finch runs
compose inside its Linux VM, so configuration comes from the `.env` file beside
the compose — an inline `VAR=… finch compose` shell export is **not** seen
inside the VM.)

## 6. Wire the reverse proxy

Point your proxy hosts at the in-network service names + ports:

| Public host | Upstream |
|---|---|
| `app.shotdeck.<domain>` | `posedeck-web:80` |
| `api.shotdeck.<domain>` | `posedeck-pb:8090` |
| `anisette.shotdeck.<domain>` | `posedeck-anisette:6969` |

Then open `https://app.shotdeck.<domain>` and sign in. (First run: create the
PocketBase admin at `https://api.shotdeck.<domain>/_/`.)

## 7. First-run admin + a real user

1. `https://api.shotdeck.<domain>/_/` → create the superuser (admin) account.
2. In the admin UI, create your photographer user in the `users` collection (or
   enable signups if you prefer), then sign in on the web app.

## 8. iOS app

The phone talks to the **same** `api.` URL. You can either bake it into the
build (`ios/PoseDeck/Config/Config.xcconfig` → `API_BASE_URL`) or — easier —
enter it at the sign-in screen via **"Use a different server"** (persisted).
SideStore signing uses the `anisette.` host — see `ios/SIDESTORE.md`.

---

## Updating after a code change

```sh
cd /mnt/tank/shotdeck && git pull
cd backend
docker compose build web        # rebuild the SPA (only if web/ or API URL changed)
docker compose up -d            # recreate changed containers
```

PocketBase updates: bump the pinned tag in `docker-compose.yml`, then
`docker compose pull pocketbase && docker compose up -d`.

## Backups

Snapshot/replicate the `pb_data/` and `anisette/` datasets (ARCHITECTURE.md
§11). `pb_data/` holds the database **and** uploaded reference photos; anisette
holds the signing keychain (losing it just means re-pairing SideStore).

## Troubleshooting

- **`required variable POSEDECK_API_URL is missing`** — you have no `backend/.env`
  (or it lacks the var). Copy `.env.example` and set it.
- **Shared decks 404** — migration `1700000009` didn't apply; confirm the file
  is in `backend/pb_migrations/` and restart PocketBase.
- **Web shows the wrong API URL** — it's baked in at build time; rebuild the web
  image after changing `.env`.
- **`network reverse-proxy not found`** — your proxy network has a different
  name; update the `networks:` block at the bottom of the compose, or create it
  (`docker network create reverse-proxy`).
