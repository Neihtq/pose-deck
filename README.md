# Pose Deck

Pose Deck is a self-hosted, two-user photo shotlist app for planning and running
photo shoots. You build *decks* of *cards* (each a planned shot with a title, time
slot, subjects, direction, notes, and reference images) on the web, then run the
deck in a swipe-driven shoot mode on iOS. It is offline-first (local-first stores
with an outbox sync layer), backed entirely by a single PocketBase instance running
on a home TrueNAS server.

## Repository layout

This is a monorepo with three deployable components plus shared docs:

| Path | What it is | Owner README |
|---|---|---|
| `backend/` | PocketBase backend — schema (JS migrations), dev/prod compose files, seed script | [`backend/README.md`](backend/README.md) |
| `web/` | React 18 + TypeScript + Vite web app (prep UI, PDF export); built into an nginx image | [`web/README.md`](web/README.md) |
| `ios/` | SwiftUI app (`PoseDeck`) + testable Swift Package logic core (`PoseDeckCore`) | `ios/` (see package READMEs) |
| `docs/` | Product, architecture, and execution docs | see below |

## Quickstart

Each component is self-contained. See the component README for full setup; the
short version:

- **Backend** — runs against the bare PocketBase binary in dev (see note below).
  Start it, apply the migrations in `backend/pb_migrations/`, and run the seed
  script. Details: [`backend/README.md`](backend/README.md).
- **Web** — `cd web && npm install`, then
  `VITE_API_BASE_URL=http://localhost:8090 npm run dev` (serves on
  `http://localhost:5173`). Details: [`web/README.md`](web/README.md).
- **iOS** — open `ios/PoseDeck/PoseDeck.xcodeproj` in Xcode; run
  `swift test` in `ios/PoseDeckCore/` for the logic core. Configure the dev API
  base URL in `Config.xcconfig`.

## Documentation

- [`docs/PROJECT_PLAN.md`](docs/PROJECT_PLAN.md) — execution plan: repo structure,
  milestone breakdown, and verification ownership per task. **Start here** to see
  what is built and what is next.
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — technical architecture: stack,
  data model, sync protocol, image pipeline, deployment topology, CI/CD.
- `docs/DESIGN.md` — product spec (the *what*).

## Deployment

Production runs as a Docker Compose stack on TrueNAS (PocketBase + web + anisette)
behind an existing reverse proxy that terminates TLS. Web images are built by CI
and pushed to GHCR; see [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) §9–§10 and
the workflows in [`.github/workflows/`](.github/workflows/).
