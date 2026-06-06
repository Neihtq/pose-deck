# Pose Deck — Backend

The entire backend is a single [PocketBase](https://pocketbase.io) instance
(DB + auth + file storage + realtime), plus a
[dadoum/anisette-v3-server](https://github.com/Dadoum/anisette-v3-server)
container used by SideStore to re-sign the iOS IPA.

The schema is **version-controlled as JavaScript migrations** in
[`pb_migrations/`](./pb_migrations) — never click-edit collections in the
admin UI for schema changes; write a migration instead. See
[`../docs/ARCHITECTURE.md`](../docs/ARCHITECTURE.md) §3 for the data model
and §9 for the deployment topology.

PocketBase is pinned to **`0.39.1`** (`ghcr.io/muchobien/pocketbase`). Bump
the tag in both compose files in lockstep after testing.

## Collections

| Collection | Type | Purpose |
|---|---|---|
| `users` | auth | Email+password accounts. Public signup disabled. |
| `decks` | base | A shotlist. Owned by one user. |
| `cards` | base | A shot within a deck. Cascade-deletes with its deck. |
| `card_images` | base | Image attached to a card. Cascade-deletes with its card. |
| `deck_guests` | base | Grants a user guest (read) access to a deck. Unique `(deck, user)`. |
| `card_completions` | base | Per-user shoot progress. Unique `(card, user)`. |

API rules (who can list/view/create/update/delete each collection) are
defined in the migrations and mirror ARCHITECTURE.md §3 exactly.

---

## Running locally

You have two options. Both apply the migrations in `pb_migrations/`
automatically on first start.

### Option A — Docker Compose (recommended)

Runs PocketBase **and** Anisette together. The seed migration runs because
`POSEDECK_DEV=true` is set in `compose.dev.yml`.

```bash
docker compose -f compose.dev.yml up
```

- PocketBase API:      http://localhost:8090
- PocketBase admin UI: http://localhost:8090/_/
- Anisette server:     http://localhost:6969

Data persists in `./pb_data` (git-ignored). To start completely fresh:

```bash
docker compose -f compose.dev.yml down
rm -rf pb_data
docker compose -f compose.dev.yml up
```

### Option B — Bare PocketBase binary

Useful when you don't need Anisette. The seed migration only runs when
`POSEDECK_DEV=true` is exported.

1. Download the binary matching the pinned version (**0.39.1**) from the
   [PocketBase releases](https://github.com/pocketbase/pocketbase/releases)
   page and unzip it into this directory (it is git-ignored):

   ```bash
   # macOS arm64 example — adjust asset for your OS/arch.
   curl -L -o pocketbase.zip \
     https://github.com/pocketbase/pocketbase/releases/download/v0.39.1/pocketbase_0.39.1_darwin_arm64.zip
   unzip pocketbase.zip pocketbase
   chmod +x pocketbase
   ```

2. Run it, pointing at the version-controlled migrations:

   ```bash
   POSEDECK_DEV=true ./pocketbase serve \
     --http=0.0.0.0:8090 \
     --dir=./pb_data \
     --migrationsDir=./pb_migrations
   ```

   PocketBase serves on http://localhost:8090 and the admin UI on
   http://localhost:8090/_/.

> Omit `POSEDECK_DEV=true` to run without the dev seed (closer to prod).

### First-run superuser

On the very first start PocketBase prints a one-time link to create the
initial superuser (admin), or you can create one explicitly:

```bash
# binary
./pocketbase superuser create admin@example.com a-strong-password --dir=./pb_data

# compose
docker compose -f compose.dev.yml exec pocketbase \
  /usr/local/bin/pocketbase superuser create admin@example.com a-strong-password --dir=/pb_data
```

---

## Dev seed data

`pb_migrations/1700000010_dev_seed.js` is **dev-only** and **idempotent**:

- It runs **only** when `POSEDECK_DEV=true` (set in `compose.dev.yml`,
  never in `docker-compose.yml`), so it can never run in production.
- It checks for existing records before creating, so restarts are safe.

It creates two users and one sample deck with three cards:

| Email | Password | Role |
|---|---|---|
| `owner@posedeck.test` | `changeme123` | deck owner |
| `guest@posedeck.test` | `changeme123` | intended guest |

These credentials are for **local development only**. Never deploy the seed
to a reachable environment.

---

## How the owner pre-creates accounts (production)

There is **no public signup** (the `users` create rule is `null`). The
owner provisions accounts manually:

1. Open the PocketBase admin UI at `https://api.shotdeck.<domain>/_/`
   (or the LAN address) and sign in as the superuser.
2. Go to **Collections → users → New record**.
3. Set the friend's **email**, a **name**, an initial **password**, and
   tick **verified**. Save.
4. Share the credentials with the friend (they can change the password
   later via the app's password-reset flow once SMTP is configured — see
   ARCHITECTURE.md §7).

To grant a guest access to a specific deck, the owner uses the in-app
"Share" action (creates a `deck_guests` row) — see ARCHITECTURE.md §6.

---

## Production deployment (deferred to M-deploy)

The production stack is [`docker-compose.yml`](./docker-compose.yml). It runs
PocketBase + the web image + Anisette, all on a pre-existing **external**
`reverse-proxy` Docker network, exposing (not publishing) ports so the
TrueNAS reverse proxy can route to them. See ARCHITECTURE.md §9 for the
TrueNAS layout and the proxy hostname routes. Do **not** deploy it from this
environment — that is a developer step on the NAS.
