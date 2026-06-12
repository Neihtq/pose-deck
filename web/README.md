# Pose Deck — Web

React 18 + TypeScript + Vite client for Pose Deck. See `../docs/ARCHITECTURE.md`
(stack §2, data model §3, sync §4) and `../docs/PROJECT_PLAN.md` (§2.2).

This is the **M1 foundation scaffold** — project setup, typed PocketBase client,
data-model types, Dexie schema, and tooling. Auth and deck/card CRUD UI are built
on top of this after review.

## Stack

- **Vite + React 18 + TypeScript**
- **Tailwind CSS + shadcn/ui** (`src/components/ui/`) for UI primitives
- **`pocketbase`** official JS SDK — typed wrapper in `src/lib/pocketbase.ts`
- **Dexie** (IndexedDB) local store — schema in `src/lib/db.ts`
- **Vitest** + Testing Library for unit/component tests

## Prerequisites

- Node 22+ and npm 10+
- A running PocketBase backend (see `../backend/`). Local default: `http://localhost:8090`.

## Setup

```bash
npm install
cp .env.example .env   # adjust VITE_API_BASE_URL if needed
```

## Develop

```bash
VITE_API_BASE_URL=http://localhost:8090 npm run dev
# http://localhost:5173
```

`VITE_API_BASE_URL` can also be set in `.env`. If unset, the client falls back
to `http://localhost:8090`.

## Test

```bash
npm test          # run once
npm run test:watch
```

## Type-check / lint

```bash
npm run lint      # tsc --noEmit
```

## Build

```bash
npm run build     # tsc -b && vite build -> dist/
npm run preview   # serve the built bundle locally
```

## Docker

The production image is nginx-alpine serving the static `dist/` bundle
(ARCHITECTURE.md §9). `VITE_API_BASE_URL` is baked in at **build time**, so the
backend URL must be passed as a build arg. In production this image is built
from source by the compose stack (`backend/docker-compose.yml` → `web.build`);
see the deploy runbook **[`../docs/DEPLOY.md`](../docs/DEPLOY.md)**. Finch is a
drop-in for `docker` here (`finch build` / `finch run`).

To build/run it standalone (e.g. a quick local check):

```bash
docker build --build-arg VITE_API_BASE_URL=https://api.shotdeck.example.com \
  -t pose-deck-web .
docker run --rm -p 8080:80 pose-deck-web
# http://localhost:8080
```

## Layout

```
src/
  lib/
    types.ts        # interfaces for all 6 collections (ARCHITECTURE.md §3)
    pocketbase.ts   # typed PocketBase client wrapper
    db.ts           # Dexie schema (decks, cards, card_images, card_completions, outbox)
    utils.ts        # cn() class-name helper
    __tests__/      # unit tests
  components/ui/    # shadcn/ui primitives (button, input)
  test/setup.ts     # Vitest setup (jest-dom + fake-indexeddb)
  App.tsx
  main.tsx
  globals.css       # Tailwind layers + design tokens
```
