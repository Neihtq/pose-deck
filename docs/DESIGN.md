# Photo Shotlist App — Specification (v1.0)

> Status: v1 scope locked via grilling session 2026-06-06. Ready for tech-stack selection and implementation planning.

## 1. Problem

A photographer prepares a list of poses/compositions before a shoot (e.g. wedding). On location they scout, assign poses to spots, then reorder by shooting sequence. During the shoot they need to mark off completed shots and see the next one instantly.

Today this is done in a notes app, which fails because:
- Mixing text + reference images is awkward.
- Hard to get an overview, organise, or navigate.
- During the shoot, scrolling/searching to cross off and find the next idea wastes time.

## 2. Users

- **Primary:** Solo photographer planning and executing a shoot. Same user uses both iOS and Web (prep on laptop, shoot on phone).
- **Secondary:** Co-photographer / second shooter — invited as a read-only guest to a deck.

## 3. Core Concepts

| Concept | Definition |
|---|---|
| **Card** | A single shot idea. Atomic unit. Bundles structured text fields + images. |
| **Deck** | An ordered, flat list of cards. One deck = one shoot. |

### 3.1 Card

| Field | Required | Notes |
|---|---|---|
| Title | yes | ≤60 chars |
| Time / slot | no | Free text ("16:30" or "during cocktails") |
| Subjects / names | no | Free text |
| Direction phrase | no | Short prompt the photographer says aloud |
| Notes | no | Free-form blob |
| Images | no | 0–5 per card |
| Completion state | derived | Per-user (not shared between owner and guests) |

### 3.2 Images

| Aspect | Rule |
|---|---|
| Max per card | 5 |
| Sources v1 | Phone library, in-app camera, clipboard paste (web + iOS) |
| Storage | Cloud-backed; synced to all owner devices |
| Compression | Auto-resize to 1080px long edge, JPEG q80; originals discarded |
| Pre-cache | Deck + all images downloaded to device before shoot (auto if shoot date within 48h, else manual toggle) |
| Card thumbnail | First image of the card |

### 3.3 Deck

| Field | Required | Notes |
|---|---|---|
| Name | yes | |
| Shoot date | no | Datetime; drives auto-pre-cache and grouping |
| Owner | yes | Implicit — current user |
| Cards | yes | Ordered, flat list |
| Sharing | optional | See §6 |
| Auto-thumbnail | derived | First image of first card |

**Operations:** create, rename, delete (30-day soft-delete trash), duplicate (poor man's templates), reorder cards (drag-drop), share.

**Lifecycle:** decks live until deleted. No auto-archive. Card completion state is permanent — to re-shoot, duplicate the deck.

**Deck list view:**
- Grouped: **Upcoming** (date ≥ today, soonest first) → **Undated** → **Past** (date < today, most recent first)
- Search by deck name

## 4. Phases

### 4.1 Preparation
**Goal:** Build and organise the deck efficiently.

**Available on:** iOS + Web (full feature parity for prep).

**UX priorities:**
- Fast card creation with mixed text + images
- Drag-and-drop reorder
- Grid/list overview at a glance
- Image attach from library / camera / clipboard
- Share deck via link or QR (see §6)
- Duplicate deck

### 4.2 Shooting
**Goal:** Execute the deck on-site with minimal friction.

**Available on:** iOS only in v1. Web shoot mode → v2.

**Read-only behaviour in v1.** No add-card, no edit-card, no reorder during shooting. Edits require switching back to prep mode. Deferred to v2.

**Card view:** image-prominent, title + time + subjects + direction visible at a glance, notes accessible via swipe-up.

**Gestures:**

| Gesture | Action |
|---|---|
| Swipe **right** | Done. Card marked completed, next card surfaces. |
| Swipe **left** | Skip for now. Card moves to end of deck. |
| Swipe **up** | Expand: full-screen image + full notes. Swipe down or tap to dismiss. |
| Tap **undo button** (top-left, large, persistent) | Reverse last swipe. |

**Indicators:**
- Progress: "Card 7 of 23"
- Skipped count: small "+3 skipped" badge if any cards have been skipped

## 5. Data sync & offline

- **Sync model:** local-first. Every action writes to local storage immediately, queued for backend sync.
- **Offline:** fully usable both phases. Pre-cached deck + images work without connectivity. Edits queue locally.
- **Conflict resolution:** last-write-wins for v1 (co-photographer collisions are rare; guests are read-only anyway).
- **Cross-device sync:** owner's deck syncs across all their devices (iOS + Web). Guests sync their personal completion state across their devices.

## 6. Sharing

**Model:** live shared deck, read-only guests, per-user progress.

- One owner per deck (the creator).
- Owner can invite guests. Guests see the deck always-up-to-date (owner edits propagate live).
- Guests cannot edit cards, reorder, or share.
- Each guest tracks their own swipe progress. Owner and guests do not see each other's completion state.

**Invite mechanism:**
- **Share link** (primary, both platforms). Owner generates a link. Recipient opens it, signs in/up, gains read-only access. Each link is revocable, expires after 30 days by default. Owner sees a list of active guests in deck settings.
- **QR code** (iOS shortcut). Renders the share link as a QR for fast face-to-face sharing.

## 7. Authentication

- **Method:** email + password.
- **Recommendation:** use a managed auth provider (Supabase Auth, Clerk, Auth0, Firebase) so password reset, breach checks, rate limiting, and session management come for free.
- Standard flows: sign up, sign in, password reset via email, account deletion.

## 8. Export

- **PDF export** of a deck. One card per page: image(s), title, time, subjects, direction, notes.
- Available from **web only** in v1 (printing flow lives there).
- Use case: hand a paper version to the wedding planner / client.

## 9. Platforms

| Platform | v1 scope |
|---|---|
| **iOS (iPhone)** | Native app. Full prep + full shoot. |
| **Web (desktop browser)** | Full prep. No shoot mode. |
| **iPad** | Runs the web app in browser. No native iPad app. |
| **Android** | Not in v1. v2+. |

## 10. Non-goals (v1)

- Calendar integration
- Client / booking management
- Photo editing or post-processing
- Payment / billing
- Public deck marketplace
- Tags / categories on cards
- Per-card timer / countdown
- Voice notes
- Real-time presence ("second shooter just completed card X")

## 11. Deferred to v2+

| Feature | Reason for deferral |
|---|---|
| Mid-shoot edits (add/edit/reorder) | Adds UI complexity in the most time-sensitive phase; v1 is read-only swipe |
| Web shoot mode | Shoot is mobile-first; preview value low for v1 |
| Sections within a deck | Flat deck + `time` field handles ordering; sections add CRUD complexity |
| Templates (formal) | "Duplicate deck" covers 80% of the value |
| URL image import (Pinterest-style) | Web-scraping fragility; clipboard paste covers most cases |
| Email magic-link auth | Email/password sufficient |
| Apple/Google sign-in | Email/password sufficient |
| Tags / categories on cards | Add when filtering becomes a real need |
| Per-card timer | Add when itinerary management proves to be a pain |
| Voice notes | Add when typing-during-prep proves to be a pain |
| Push notifications | "Shoot in 24h, deck pre-cached ✅" reminder |
| Real-time collaboration (multi-editor) | Complexity not justified for v1 |
| Native iPad app | Web works; native is polish |
| Android | Build after iOS validates |

## 12. Open: tech stack

Not locked. Recommended starting points (decide before implementation):

**Backend:**
- **Supabase** — managed Postgres + email/password auth + storage + realtime subscriptions. Single dependency, generous free tier, great fit for local-first sync.
- Alternatives: Firebase (Google-centric), custom (own infra, more work).

**Sync layer (local-first):**
- **PowerSync** or **ElectricSQL** on top of Supabase — proper offline-first with sync engine.
- Alternative: roll your own with Supabase realtime + a queue of pending mutations. Simpler initially, harder at scale.

**iOS:**
- **Swift / SwiftUI** native. SwiftData or Core Data for offline storage. Best UX, App Store native.
- Alternative: React Native / Flutter — share code with web, but compromised native feel.

**Web:**
- **React + TypeScript** + a UI library (shadcn/ui, Mantine, or similar). PWA-capable for installability.
- Alternative: SvelteKit, Vue/Nuxt — pick what you know.

**Decision criteria:**
- How much do you want to share code between iOS and web? (None → native iOS + separate React web. Lots → React Native + RN-Web.)
- Solo developer or team? (Solo → minimize stacks. Team → optimize for parallel work.)
- Time to first deploy? (Supabase + native iOS + React web ≈ 2 weeks for skeleton.)

---

## Appendix: decisions log (grilling session 2026-06-06)

| # | Decision | Choice |
|---|---|---|
| Q1 | iOS + Web for same user | Yes — sync required |
| Q2 | Offline support | Fully offline, both phases |
| Q3 | Sharing model | Live shared, read-only guests, per-user progress |
| Q4 | Card structure | Lightly structured (Title, Time, Subjects, Direction, Notes, Images) |
| Q5 | Shooting-phase swipes | Right=done, Left=skip→end, Up=expand, Undo button |
| Q6 | Deck granularity | Flat deck per shoot |
| Q7 | Mid-shoot edits | None in v1 (read-only) |
| Q8 | Image handling | 5 max, library/camera/clipboard, 1080p compress, cloud-backed |
| Q9 | Web parity | Prep only, no shoot mode |
| Q10 | Auth | Email + password |
| Q11 | Sharing invite | Share link primary + QR shortcut on iOS |
| Q12 | Reusable decks | Duplicate action only (no formal templates) |
| Q13 | Misc bundle | Approved (deck metadata, export, iPad-as-web, no notifications) |

— end v1.0 —

