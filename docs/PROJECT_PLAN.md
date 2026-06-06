# Pose Deck — Project Plan (v1.0)

> Companion to `DESIGN.md` (the *what*) and `ARCHITECTURE.md` (the *how*).
> This document is the *execution plan*: repo layout, milestone breakdown into
> checkable tasks, and — critically — **who builds/verifies each piece** given the
> constraints of the development environment.

## 0. How we work

This project is built by an AI agent (Claude) pairing with the developer. The two
have different capabilities, so every task is tagged with a **verification owner**.

| Tag | Meaning | Who |
|---|---|---|
| 🤖 **AGENT-FULL** | Agent writes the code, builds it, AND runs it / its tests to confirm it works. | Claude, end-to-end |
| 🟡 **AGENT-COMPILE** | Agent writes the code and compiles it (catches type errors, missing symbols, build failures) but **cannot run it**. | Claude writes + `xcodebuild build`; dev runs |
| 👤 **DEV-VERIFY** | Requires a real device, simulator, GUI, camera, or external service the agent can't drive. Agent writes; **developer builds & verifies**. | Developer |

### Environment capabilities (verified 2026-06-06)

| Capability | Status |
|---|---|
| Node / npm / Vite / React build + run | ✅ Full — agent can build *and* run the web app and its tests |
| PocketBase (Docker or local binary) | ✅ Full — agent can run the backend, apply schemas, hit the API |
| Xcode 16.3 / Swift 6.1 compiler | ✅ Present — agent can **compile** Swift |
| iOS Simulator runtime | ❌ Broken in this env (`liblaunch_sim.dylib could not be opened`) — agent **cannot run** the iOS app |
| Physical iPhone, camera, SideStore, BGTasks | ❌ Developer-only |

**Consequence for iOS:** Answer to "do I always build whenever you're finished?" → **mostly, but not blindly.**
The agent compiles every iOS change (so it won't hand you code that doesn't build) and
runs unit tests on the pure-logic core. What the developer must verify on device:
visual SwiftUI layout, swipe-gesture feel, camera/clipboard, background pre-cache,
and SideStore install. To shrink that surface, the iOS app is split so the testable
logic lives in a Swift Package (see §2.3).

### The milestone loop

For each milestone:
1. Agent implements all tasks, self-verifying everything in its capability (🤖 / 🟡).
2. Agent runs the **milestone gauntlet** (see below) — a non-skippable review + test gate.
3. Agent writes a **handoff note**: what was built, what the agent verified, and the
   exact steps for the developer to verify the 👤 items.
4. Developer builds/runs, reports back.
5. Agent fixes fallout. Milestone closes when the developer signs off.
6. Move to the next milestone.

### The milestone gauntlet (mandatory gate before commit)

Parallel-generated code produces plausible-but-compiles bugs that self-review misses
(M1's critical `owner`-missing-on-create — which 400'd *every* deck create — was caught
only here). So every milestone runs a standardized gauntlet, implemented as the reusable
workflow `.claude/workflows/milestone-gauntlet.js`:

1. **Adversarial review** — parallel hostile lenses (correctness, spec-conformance,
   security, react/async) try to *break* the diff.
2. **Independent refutation** — each finding is cross-examined by a separate skeptic whose
   default position is "false positive"; only findings proven against the real code survive.
3. **Auto-fix** — **every** confirmed finding of **all** severities is fixed (decided
   2026-06-06), each with a **regression test** that fails before and passes after.
4. **Test layers (all four required each milestone):**
   - **Component** (RTL + vitest, mocked backend)
   - **Integration** (vitest against a live ephemeral PocketBase — API rules, soft-delete,
     visibility, cascade)
   - **E2E** (Playwright — full browser flows)
   - **Regression** (one per confirmed finding, from step 3)
5. **Re-verify** — build + test + lint green, then handoff report.

Layers that genuinely can't execute in this environment (e.g. Playwright without a
browser, iOS without a device) are *scaffolded* and marked SKIPPED with the exact blocker
for the developer — never silently dropped.

---

## 1. Repository structure (monorepo)

```
pose-deck/
├── docs/
│   ├── DESIGN.md            # product spec
│   ├── ARCHITECTURE.md      # technical architecture
│   └── PROJECT_PLAN.md      # this file
├── backend/
│   ├── docker-compose.yml          # production stack (PocketBase + web + anisette)
│   ├── compose.dev.yml             # local dev (PocketBase + anisette)
│   ├── pb_migrations/              # PocketBase schema as JS migrations (version-controlled)
│   └── README.md
├── web/
│   ├── src/
│   │   ├── lib/                     # pocketbase client, sync/outbox, db (Dexie)
│   │   ├── features/               # decks, cards, images, auth, export
│   │   ├── components/ui/          # shadcn/ui primitives
│   │   └── routes/
│   ├── public/
│   ├── index.html
│   ├── package.json
│   ├── vite.config.ts
│   ├── tailwind.config.ts
│   ├── Dockerfile                  # nginx-alpine + dist/
│   └── nginx.conf
├── ios/
│   ├── PoseDeckCore/               # Swift Package — testable logic core
│   │   ├── Sources/PoseDeckCore/   # models, APIClient, Outbox, sync
│   │   ├── Tests/PoseDeckCoreTests/
│   │   └── Package.swift
│   └── PoseDeck/                   # Xcode app target — SwiftUI shell
│       ├── PoseDeck.xcodeproj
│       └── PoseDeck/
├── .github/workflows/              # CI: web image → GHCR, iOS IPA → release
└── README.md
```

**Rationale:** mirrors the deployment layout in ARCHITECTURE.md §9, keeps all three
components versioned together (easy for a solo dev), and isolates the iOS logic core
as a package the agent can test independently of Xcode/simulator.

---

## 2. Stack decisions locked

### 2.1 Backend
- PocketBase pinned image `ghcr.io/muchobien/pocketbase` at a fixed tag.
- Schema managed as **JS migrations** in `pb_migrations/` (version-controlled, reproducible) rather than clicking through the admin UI.
- Collections per ARCHITECTURE.md §3: `users`, `decks`, `cards`, `card_images`, `deck_guests`, `card_completions`.

### 2.2 Web
- React 18 + TypeScript + Vite. shadcn/ui + Tailwind. dnd-kit (reorder), framer-motion.
- Dexie for IndexedDB local store. `pocketbase` official JS SDK. `@react-pdf/renderer` for export.
- Vitest + React Testing Library for tests. Playwright optional later for e2e.

### 2.3 iOS — package + app split
- **`PoseDeckCore`** (SPM): `Codable` models, `APIClient` (REST + realtime), `Outbox`, sync engine, conflict-resolution logic, image compression helpers. Fully unit-tested; **agent runs these tests** via `swift test`.
- **`PoseDeck`** (Xcode app): SwiftUI views, SwiftData persistence wiring, gestures, camera, BGTasks. Agent compile-checks; **dev verifies on device.**

---

## 3. Milestones

Legend: 🤖 agent-full · 🟡 agent-compile-only · 👤 dev-verify

### M0 — Backend foundation  ·  target: 1 session
- [ ] 🤖 `compose.dev.yml` (PocketBase + anisette) runs locally
- [ ] 🤖 PocketBase migrations for all 6 collections with fields, types, indexes
- [ ] 🤖 API rules (list/view/create/update/delete) per ARCHITECTURE.md §3
- [ ] 🤖 Composite unique constraints: `deck_guests(deck,user)`, `card_completions(card,user)`
- [ ] 🤖 Disable public signup; document admin-creates-account flow
- [ ] 🤖 Seed script: 2 users + a sample deck for development
- [ ] 🤖 Smoke test: auth, CRUD, relation visibility rules via REST
- [ ] 🤖 `docker-compose.yml` (prod stack) authored (not deployed)
- **Handoff:** agent confirms API works end-to-end against a running PocketBase. Dev later deploys to TrueNAS (👤, deferred to M-deploy).

### M1 — Web prep MVP  ·  target: 2 sessions
- [ ] 🤖 Vite + React + TS + Tailwind + shadcn/ui scaffold
- [ ] 🤖 PocketBase client + auth (sign in, sign out, session persistence, 401 refresh)
- [ ] 🤖 Deck list view: grouped Upcoming/Undated/Past, search by name
- [ ] 🤖 Deck CRUD: create, rename, delete (soft-delete/trash), duplicate
- [ ] 🤖 Card CRUD: all fields (title, time, subjects, direction, notes)
- [ ] 🤖 Image upload: library + clipboard paste, client compress 1080px/q80, 0–5 per card
- [ ] 🤖 Drag-drop reorder (dnd-kit) with gap-based `position`
- [ ] 🤖 Card grid/list overview
- [ ] 🤖 Vitest unit tests for lib + reducers; component tests for key flows
- **Handoff:** agent runs the web app + tests locally and reports. Dev can `npm run dev` to click around (👤 optional sanity).

### M2 — iOS prep MVP  ·  target: 2 sessions
- [ ] 🟡 Xcode project + `PoseDeckCore` package wired in
- [ ] 🤖 `PoseDeckCore`: models, APIClient (auth + CRUD), unit-tested
- [ ] 🟡 Auth screen + keychain/SwiftData token storage
- [ ] 🟡 Deck list (grouped) + deck detail
- [ ] 🟡 Card CRUD screens
- [ ] 🟡 Image upload from library + clipboard; compression in `PoseDeckCore`
- [ ] 🤖 `swift test` green for `PoseDeckCore`
- **Handoff:** agent compiles app + runs core tests. **Dev builds in Xcode, runs on device/simulator, verifies UI & image picker** (👤).

### M3 — Sync layer + realtime + offline  ·  target: 2 sessions
- [ ] 🤖 Web: Dexie schema, outbox table, mutation flow, FIFO processor w/ backoff
- [ ] 🤖 Web: PocketBase realtime subscription + last-write-wins merge
- [ ] 🤖 Web: service-worker pre-cache + manual "download for offline"
- [ ] 🟡 iOS `PoseDeckCore`: outbox + sync engine (unit-tested 🤖)
- [ ] 🟡 iOS: SwiftData mirror + realtime + BGAppRefreshTask pre-cache
- [ ] 🤖 Cross-client sync test: mutate on web, observe propagation (agent-driven where possible)
- **Handoff:** agent verifies web sync fully + iOS core sync tests. Dev verifies iOS offline/background on device (👤).

### M4 — iOS shoot mode  ·  target: 1–2 sessions
- [ ] 🟡 Swipe gestures: right=done, left=skip→end, up=expand
- [ ] 🟡 Persistent undo button (reverse last swipe)
- [ ] 🟡 Card view: image-prominent, title/time/subjects/direction, swipe-up notes
- [ ] 🟡 Progress "Card 7 of 23" + "+N skipped" badge
- [ ] 🤖 `card_completions` write logic in `PoseDeckCore` (unit-tested)
- **Handoff:** **dev verifies swipe feel on real device** — core gesture UX, can't be agent-tested (👤).

### M5 — Sharing  ·  target: 0.5 session
- [ ] 🤖 Backend `deck_guests` grant/revoke flows verified
- [ ] 🤖 Web: deck-settings share/revoke UI + realtime propagation
- [ ] 🟡 iOS: same share/revoke UI
- **Handoff:** agent verifies web + backend; dev verifies iOS propagation (👤).

### M6 — PDF export (web)  ·  target: 0.5 session
- [ ] 🤖 `@react-pdf/renderer` doc: cover page + one card/page
- [ ] 🤖 Pulls images from local cache; downloads blob
- [ ] 🤖 Agent generates a sample PDF and inspects output
- **Handoff:** fully agent-verifiable.

### M7 — SideStore distribution  ·  target: 0.5 session
- [ ] 🟡 GitHub Actions: `xcodebuild archive` + export unsigned IPA
- [ ] 🤖 AltStore source `apps.json` manifest generation
- [ ] 👤 Anisette container deploy + SideStore install on device
- **Handoff:** mostly dev — install + sign flow is device-only (👤).

### M8 — Polish + first real shoot  ·  target: 1 session
- [ ] 🤖 Web polish, a11y pass, error states
- [ ] 🟡 iOS polish
- [ ] 👤 End-to-end dry run: prep on web → shoot on phone → export

### M-deploy — TrueNAS deployment  ·  (whenever ready)
- [ ] 👤 Deploy compose stack to TrueNAS, wire reverse proxy routes, TLS
- [ ] 👤 ZFS snapshot + replication tasks
- [ ] 🤖 CI for web image → GHCR

---

## 4. Sequencing notes

- **M0 → M1 → M2** is the natural order: backend contract first, then the client the
  agent can fully verify (web), then iOS.
- **M3 (sync)** lands after both clients have basic CRUD so there's something to sync.
- iOS-heavy milestones (M2, M4) have the largest 👤 surface — expect more back-and-forth.
- Deployment (M-deploy) is decoupled; we develop against local PocketBase throughout.

## 5. Definition of done (per milestone)

1. All 🤖 tasks self-verified by the agent (builds + runs + tests green).
2. All 🟡 tasks compile cleanly.
3. **Milestone gauntlet passed:** adversarial review run, **0 unaddressed confirmed
   findings** (all severities auto-fixed with regression tests), and the four test layers
   present (component + integration + e2e + regression) — each green or SKIPPED with a
   documented blocker.
4. Handoff note written.
5. Developer signs off on 👤 items.
6. Code committed (per-component commits in the monorepo).

— end Project Plan v1.1 —
