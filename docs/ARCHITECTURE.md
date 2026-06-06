# Photo Shotlist App — Architecture (v1.0)

> Companion to `SPEC.md`. Captures stack, data model, sync protocol, and deployment for a self-hosted, 2-user private project.

## 1. Component overview

```
┌─────────────────────────────────────────────────────────────────┐
│  iOS (Swift/SwiftUI)              Web (React/TS)                 │
│  ┌────────────┐                   ┌────────────┐                 │
│  │ UI layer   │                   │ UI layer   │                 │
│  │ SwiftData  │                   │ Dexie      │                 │
│  │ Outbox     │                   │ Outbox     │                 │
│  │ Sync svc   │                   │ Sync svc   │                 │
│  └─────┬──────┘                   └─────┬──────┘                 │
└────────┼────────────────────────────────┼─────────────────────────┘
         │ HTTPS                          │ HTTPS
         ▼                                ▼
   ┌─────────────────────────────────────────────┐
   │  Existing reverse proxy on TrueNAS           │
   │  (NPM / Traefik / Caddy — already running)   │
   └────────────────┬───────────────┬─────────────┘
                    │               │
            ┌───────▼─────┐   ┌─────▼──────┐
            │ PocketBase  │   │ Anisette   │
            │ (backend)   │   │ (sideload) │
            └─────┬───────┘   └────────────┘
                  │
         ┌────────▼────────┐
         │ pb_data         │
         │ (ZFS dataset)   │
         └─────────────────┘
```

Three containers in a single docker-compose stack on TrueNAS:
- **PocketBase** — DB + auth + storage + realtime (the entire app backend)
- **Web** — nginx-alpine serving the React static bundle
- **Anisette** — `dadoum/anisette-v3-server` for SideStore IPA re-signing

All three plug into the existing reverse-proxy network. No Caddy / Cloudflare Tunnel — the existing proxy handles routing + TLS.

## 2. Tech stack

| Layer | Choice | Why |
|---|---|---|
| Backend | **PocketBase** (single Go binary, SQLite) | Self-hosted, single dependency, all features built-in |
| iOS app | **Swift 5.9 / SwiftUI**, SwiftData, async-await | Native swipe physics, best UX for shoot mode |
| Web app | **React 18 + TypeScript + Vite** | Standard, well-tooled, mature |
| Web UI | **shadcn/ui + Tailwind**, **dnd-kit**, **framer-motion** | Modern, accessible, drag-drop ready |
| Web local store | **Dexie** (IndexedDB wrapper) | Persistent, indexed, offline |
| Web PDF | **`@react-pdf/renderer`** | Client-side, React-component model |
| iOS PocketBase SDK | **PocketBase Swift SDK** (community) or thin custom wrapper | Native auth + REST + realtime |
| Web PocketBase SDK | **`pocketbase`** (official) | First-party JS client |
| Sync model | **Outbox pattern** (custom, ~1-2 weeks per client) | Simple, debuggable, fits our concurrency profile |
| iOS distribution | **SideStore + self-hosted Anisette** | No Apple Dev account required |
| Web distribution | Static bundle in nginx container | Served by reverse proxy at root domain |
| TLS | Existing reverse proxy on TrueNAS | Already in place |
| CI/CD | **GitHub Actions** | Build IPA on macOS runner; build web image, push to GHCR |
| Backup | **TrueNAS ZFS snapshots** + replication | Native, atomic, free |

## 3. Data model

PocketBase collections:

### 3.1 `users` (built into PocketBase auth)
| Field | Type | Notes |
|---|---|---|
| id | string | PocketBase-generated |
| email | string, unique | |
| password | string, hashed | Managed by PocketBase |
| name | string | Display name |
| created, updated | datetime | |

**Auth rules:**
- `allowEmailAuth: true`
- `allowOAuth2Auth: false`
- `allowUsernameAuth: false`
- **Public signup disabled.** Owner pre-creates the friend's account via PocketBase admin UI.

### 3.2 `decks`
| Field | Type | Notes |
|---|---|---|
| id | string | |
| owner | relation → users | required |
| name | string | required, max 200 |
| shoot_date | datetime | optional |
| client_updated_at | datetime | for last-write-wins conflict resolution |
| created, updated | datetime | server-managed |
| deleted_at | datetime | optional, soft-delete |

**API rules:**
- `listRule`: `owner = @request.auth.id || @collection.deck_guests.deck = id && @collection.deck_guests.user = @request.auth.id`
- `viewRule`: same as `listRule`
- `createRule`: `@request.auth.id != ""` (any authenticated user)
- `updateRule`: `owner = @request.auth.id`
- `deleteRule`: `owner = @request.auth.id`

### 3.3 `cards`
| Field | Type | Notes |
|---|---|---|
| id | string | |
| deck | relation → decks | required, cascade-delete |
| position | number | for ordering; gaps allowed (integers like 1000, 2000, …) |
| title | string | required, max 200 |
| time_slot | string | optional |
| subjects | string | optional |
| direction | string | optional |
| notes | string | optional, no length cap |
| client_updated_at | datetime | |
| created, updated | datetime | |
| deleted_at | datetime | optional, soft-delete |

**API rules:** inherit visibility from parent deck (mirrors deck rules, joined through `deck` relation).

### 3.4 `card_images`
| Field | Type | Notes |
|---|---|---|
| id | string | |
| card | relation → cards | required, cascade-delete |
| position | number | for ordering within a card |
| file | file | PocketBase file field — stored on disk, max 1 file per record |
| created | datetime | |

**API rules:** inherit from parent card. PocketBase auto-handles per-file signed URL generation.

### 3.5 `deck_guests`
Records which users have access to which decks. Replaces share-link/QR for v1 (private 2-user project).

| Field | Type | Notes |
|---|---|---|
| id | string | |
| deck | relation → decks | |
| user | relation → users | |
| granted_at | datetime | |

**Composite unique:** `(deck, user)`.

**API rules:**
- `listRule`: `deck.owner = @request.auth.id || user = @request.auth.id`
- `createRule`: `deck.owner = @request.auth.id` (only owner can grant)
- `deleteRule`: `deck.owner = @request.auth.id` (only owner can revoke)

### 3.6 `card_completions`
Per-user shoot progress.

| Field | Type | Notes |
|---|---|---|
| id | string | |
| card | relation → cards | |
| user | relation → users | |
| state | enum | `done` \| `skipped` \| `pending` |
| changed_at | datetime | |

**Composite unique:** `(card, user)`.

**API rules:**
- `viewRule` / `listRule`: `user = @request.auth.id` (you only see your own progress)
- `createRule` / `updateRule`: `user = @request.auth.id` && card is in a deck you own or guest

## 4. Sync architecture (outbox pattern)

### 4.1 Local store

**iOS (SwiftData):**
- Mirror collections as SwiftData entities.
- `OutboxEntry` table: id, type (create/update/delete), entity, payload (JSON), idempotency_key (UUID), local_timestamp, retry_count, last_error.

**Web (Dexie/IndexedDB):**
- Same shape: `decks`, `cards`, `card_images`, `card_completions`, `outbox` tables.

### 4.2 Mutation flow

1. User performs action (e.g. "create card").
2. Client writes to **local store immediately** (UI updates optimistically).
3. Client appends an entry to **outbox** with idempotency_key.
4. If online: outbox processor sends entries to PocketBase REST API in FIFO order.
5. PocketBase responds 200 → outbox entry deleted, local store updated with server-canonical values (server `id`, timestamps).
6. PocketBase responds 4xx → log, drop entry, surface error to UI.
7. Network error / 5xx → exponential backoff, retry.

### 4.3 Conflict resolution

Last-write-wins per record using `client_updated_at`:
- Client always sends `client_updated_at` set to local time at mutation.
- Server records both `client_updated_at` (client clock) and `updated` (server clock).
- On incoming realtime event, client compares server `client_updated_at` against its own local `client_updated_at`:
  - If server's is newer → apply update locally.
  - If local is newer → skip (don't overwrite local pending state).
- Realistic conflicts: vanishingly rare given 1 owner per deck and read-only guests.

### 4.4 Realtime subscription

- On login, subscribe via PocketBase Realtime to:
  - `decks`, `cards`, `card_images`, `deck_guests`, `card_completions`.
- Server filters events server-side using collection rules — clients only receive events for records they can see.
- Incoming event → apply through last-write-wins merge.

### 4.5 Pre-cache for offline

**iOS:**
- Background Tasks framework: `BGAppRefreshTask` registers a periodic refresh.
- Custom logic: if any deck has `shoot_date` within 48h, ensure deck + cards + image bytes are downloaded.
- Manual: per-deck "Download for offline" toggle that pins the deck.

**Web:**
- Service worker caches API responses + image blobs per deck.
- `Cache-Control` on image responses leverages browser HTTP cache.
- Manual "Download for offline" toggle persists deck data + images in IndexedDB.

## 5. Image pipeline

1. User picks image (library / camera / clipboard paste).
2. Client compresses: 1080px long edge, JPEG quality 80. Discards original.
3. Client computes a content hash (SHA-256) for dedup-on-upload.
4. POST to PocketBase `/api/collections/card_images/records` with `multipart/form-data`. PocketBase persists the file under `pb_data/storage/<collection>/<record_id>/<filename>`.
5. PocketBase response includes the file URL.
6. Client caches the compressed bytes locally (SwiftData blob / IndexedDB blob) keyed by URL.
7. On display: read from local cache; fall back to URL fetch.

**Display URLs:** PocketBase serves files via `/api/files/<collection>/<recordId>/<filename>`. Auth is enforced — the app passes the user's auth token; PocketBase rejects requests for files in records the user can't view.

## 6. Sharing (simplified for 2-user private project)

v1 has no public share-link / QR flow. Owner explicitly grants guest access:

1. Owner opens deck settings on web or iOS.
2. UI shows a list of users (just one entry — the friend — pre-created in PocketBase admin).
3. Owner taps "Share with [friend]" → client POSTs `deck_guests` row.
4. Realtime push notifies friend's device → friend sees the deck appear in their list.
5. Owner taps "Revoke" → client deletes `deck_guests` row → realtime push removes deck from friend's UI.

If you ever want to grow beyond 2 users:
- Re-enable PocketBase signup.
- Add a share-link flow (generate token, public landing page that creates `deck_guests` row on accept).
- Add QR code rendering on iOS (`AVFoundation` or any Swift QR lib).

## 7. Authentication

- **Method:** email + password. PocketBase handles hashing (bcrypt), reset, rate limiting.
- **No public signup** in v1. Owner creates accounts via PocketBase admin UI (`/_/`).
- **Password reset:** PocketBase has built-in password reset email. Configure SMTP in PocketBase settings (e.g. SMTP2GO, your own mail server, or skip and reset via admin UI).
- **Sessions:** PocketBase issues JWT auth tokens. Stored in SwiftData / IndexedDB. Auto-refresh on 401.

## 8. PDF export

- Web only.
- Uses `@react-pdf/renderer` to produce a PDF document at runtime.
- Layout: cover page (deck name, shoot date), then one page per card with image, title, time, subjects, direction, notes.
- Image data sourced from local cache (already pre-fetched).
- Generated blob → user downloads.

## 9. Deployment topology

```
TrueNAS Scale Apps → docker compose stack:
  /mnt/tank/shotdeck/
    docker-compose.yml
    pb_data/                ← PocketBase data + storage (ZFS dataset)
    anisette/               ← Anisette server keychain
    web/                    ← nginx static serve
```

```yaml
# /mnt/tank/shotdeck/docker-compose.yml
services:
  pocketbase:
    image: ghcr.io/muchobien/pocketbase:latest
    container_name: shotdeck-pb
    restart: unless-stopped
    volumes:
      - /mnt/tank/shotdeck/pb_data:/pb_data
    networks: [reverse-proxy]
    expose: ["8090"]

  web:
    image: ghcr.io/<you>/shotdeck-web:latest
    container_name: shotdeck-web
    restart: unless-stopped
    networks: [reverse-proxy]
    expose: ["80"]

  anisette:
    image: dadoum/anisette-v3-server:latest
    container_name: shotdeck-anisette
    restart: unless-stopped
    volumes:
      - /mnt/tank/shotdeck/anisette:/home/Alcoholic/.config/anisette-v3
    networks: [reverse-proxy]
    expose: ["6969"]

networks:
  reverse-proxy:
    external: true
```

**Reverse proxy routes (you configure in your existing proxy UI/config):**
- `app.shotdeck.yourdomain.com` → `shotdeck-web:80`
- `api.shotdeck.yourdomain.com` → `shotdeck-pb:8090`
- `anisette.shotdeck.yourdomain.com` → `shotdeck-anisette:6969`

## 10. CI/CD

### iOS (GitHub Actions on macOS runner)
1. PR / merge to `main` triggers workflow.
2. Workflow runs `xcodebuild archive` + `xcodebuild -exportArchive` to produce unsigned `.ipa`.
3. Workflow uploads `.ipa` to a GitHub Release (or `rsync`s to TrueNAS via SSH).
4. Workflow updates `apps.json` manifest in your AltStore-source repo.
5. Next time you/friend opens SideStore: detects new version → downloads → signs → installs.

### Web (GitHub Actions Linux runner)
1. PR / merge to `main` triggers workflow.
2. `npm ci && npm run build` produces static bundle in `dist/`.
3. Workflow builds Docker image (nginx-alpine + `dist/` copied to `/usr/share/nginx/html/`).
4. Pushes to GHCR with tag = git SHA + `latest`.
5. TrueNAS: `docker compose pull && docker compose up -d` (manual or via webhook).

### Backend (PocketBase upstream image)
- Pin to a specific tag in compose (`pocketbase:0.22.x`). Update manually after testing.
- If you write Go hooks for custom logic later, build a custom image instead.

## 11. Backup & disaster recovery

**TrueNAS native ZFS:**
- Periodic Snapshot Task on `tank/shotdeck`:
  - Hourly snapshots, 7-day retention.
  - Daily snapshots, 30-day retention.
- Replication Task to second pool / external USB / remote TrueNAS for offsite.
- Optional: rclone push of `pb_data/data.db` to Backblaze B2 weekly for true-offsite cloud backup.

**Restore:**
- `zfs rollback tank/shotdeck@snapshot-name` for in-place restore.
- For granular restore: `zfs clone` snapshot to a new dataset, copy file out, destroy clone.

## 12. Local development

**Backend:**
```bash
docker compose -f compose.dev.yml up
# pocketbase running on http://localhost:8090
# anisette on http://localhost:6969
```

**iOS:**
- Open `Shotdeck.xcodeproj` in Xcode.
- Configure dev API base URL in `Config.xcconfig`: `API_BASE_URL=http://192.168.1.X:8090` (your TrueNAS LAN IP) or `http://localhost:8090`.
- Run on simulator or sideload to physical device for swipe testing.

**Web:**
```bash
cd web/
npm install
VITE_API_BASE_URL=http://localhost:8090 npm run dev
# http://localhost:5173
```

## 13. Cost summary

| Item | Cost |
|---|---|
| TrueNAS server | already owned |
| Domain | ~€10-15/yr |
| Apple Developer account | **$0** (free Apple ID via SideStore) |
| Mac for iOS development | already owned |
| Backup off-site B2 (optional, ~10GB) | ~$0.05/mo |
| **Total** | **~€15/yr** |

## 14. Risks & mitigations

| Risk | Mitigation |
|---|---|
| Anisette breaks after Apple auth update | Pin to last-known-good image; subscribe to project releases. Re-build & redeploy when patched. |
| 7-day cert expiration mid-shoot | Refresh Saturday morning before shoot, every shoot. Add to your prep checklist. |
| TrueNAS unreachable from venue | Pre-cache deck before leaving home. Local-first design means shoot mode works fully offline. |
| Free Apple ID rate limit (3 apps / 10 IDs per week) | Trivial for 2 users, 1 app. Use the same Apple ID indefinitely. |
| Image storage growth | Auto-compression caps individual size. Periodic cleanup via PocketBase admin if abandoned decks pile up. |
| PocketBase upgrade breaks something | Test in dev compose first. ZFS snapshot pre-upgrade. Roll back if needed. |
| Solo dev burnout | Scope is intentionally tight. v1 is shippable in 4-6 weekends if focused. |

## 15. Implementation milestones (proposed)

| Milestone | Scope | Effort |
|---|---|---|
| M0 | Backend up: docker compose, PocketBase, schemas, anisette container, reverse proxy routing | 1 day |
| M1 | Web prep MVP: auth, deck CRUD, card CRUD, image upload, deck list, drag-drop reorder | 2 weekends |
| M2 | iOS prep MVP: auth, deck list, deck detail, card CRUD, image upload | 2 weekends |
| M3 | Outbox sync layer (both clients) + realtime subscription + offline pre-cache | 2 weekends |
| M4 | iOS shoot mode: swipe gestures, undo, expand view, progress indicator | 1-2 weekends |
| M5 | Sharing (deck_guests grant + realtime propagation) | 0.5 weekend |
| M6 | PDF export from web | 0.5 weekend |
| M7 | SideStore integration: build IPA, host AltStore source, install | 0.5 weekend |
| M8 | Polish, testing, first real shoot | 1 weekend |

**Total:** ~10-12 weekends from zero to running at a real shoot.

— end Architecture v1.0 —

