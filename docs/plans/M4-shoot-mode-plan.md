# M4 Shoot Mode — Implementation Plan (vetted via design+adversarial-review 2026-06-07)

I have everything needed. All five load-bearing facts the review verdict depends on are confirmed in the actual code. Note one important correction the verdict raised: `MirrorDeckRepository(store:outbox:)` is constructed with just store+outbox (not a `writePath`/`now`), so the FILES design's "same store/outbox/writePath/now shape" is slightly off — the mirror repos build their own OfflineWritePath internally or take store+outbox. I'll account for this. Now I'll produce the consolidated plan.

# M4 Shoot Mode — Consolidated Implementation Plan (vetted)

This plan folds every confirmed critical/major review fix into the design. Each fix is tagged `[FIX-Cn]` / `[FIX-Mn]` and pinned to a code fact I verified in the repo. **No code is written yet** — this is the build order.

## Verified preconditions (load-bearing facts, confirmed in repo)

- **M3 realtime consumption of `card_completions` already exists** — `RealtimeClient.swift:189` subscription list includes `card_completions`; `SyncEngine.swift:80-81,167-171` decodes and `upsertCardCompletion`s with LWW. **Correction to the brief:** the "M3 deferred consumption that must land here" is *not* a real gap. Only the **write path** and the **deck-scoped read** are missing, plus the **backfill fetch**. Do not re-implement realtime consumption.
- `MutationSender.classify` (`MutationSender.swift:114-117`) returns bare `.success` on a duplicate-id 400 for creates — **never patches** → confirms `[FIX-C1]`.
- `MutationSender.isDuplicateIdError` (`:137-147`) only checks `data["id"] != nil` — a format-error 400 also passes → confirms `[FIX-m3]`.
- `InMemoryOutbox.pending()` (`Outbox.swift:107`) is a **non-stable** `sorted { localTimestamp < }`, and `OfflineWritePath.enqueue` (`:241`) stamps `localTimestamp: now()` with no sequence → confirms `[FIX-C2]`.
- `LWW.shouldApply` (`LocalStore.swift:63-69`) skips ties (`lhs > rhs`); `upsertCardCompletion` (`:220-224`) routes through it → confirms `[FIX-M1]` (equal-tick optimistic write is a silent no-op).
- `IDGenerator.alphabet`/`idLength` = `[a-z0-9]`,15 (`IDGenerator.swift:19-22`) → deterministic id must map through this exact charset `[FIX-m3]`.
- Mirror repo ctor shape is `MirrorDeckRepository(store:outbox:)` (`SyncCoordinator.swift:329-339`) — **not** `store/outbox/writePath/now`. New mirror completion repo must match the real pattern (build its own `OfflineWritePath`), and `makeCardCompletionRepository()` slots beside the existing factories.

---

## PHASE A — PoseDeckCore: pure state machine + write path (all `swift test`-verifiable)

Build and `swift test` green before touching the app.

### A1. `CardCompletion.deterministicId` `[FIX-m3]`
File: `ios/PoseDeckCore/Sources/PoseDeckCore/Models/CardCompletion.swift` (edit)
- Add `static func deterministicId(card:user:) -> String`: SHA-256 of `"\(card)|\(user)"`, then **map hash bytes into `IDGenerator.alphabet`, take 15** (do NOT emit raw hex — must satisfy `^[a-z0-9]{15}$`). Use `import Crypto`/CryptoKit.
- Test (in CardCompletionWritePathTests or a small IdTests): output matches `^[a-z0-9]{15}$`, stable, distinct per `(card,user)`.

### A2. `ShootSession` pure value type
File: `ios/PoseDeckCore/Sources/PoseDeckCore/Shoot/ShootSession.swift` (new)
- `struct ShootSession: Sendable`, no I/O, no clock. State: `workingOrder:[String]`, `index:Int`, `doneIds:Set<String>`, `skippedActiveIds:Set<String>`, `undoStack:[UndoFrame]`. `UndoFrame` = `.done(cardId,fromIndex)` / `.skip(cardId,fromIndex,movedToIndex)`.
- Init from non-soft-deleted cards in `position` order. Done cards stay in `workingOrder`; `currentCardId` = first id at/after `index` not in `doneIds`.
- Ops: `markDone()`, `skip()` (append to end), `undo()` (LIFO, fully reverses order+cursor+sets).
- **`[FIX-M2]` semantics — resolve the three spec-drift questions explicitly (decision baked in, test-pinned):**
  - **`[FIX-M2a]` "Card N of M":** the brief's `N = doneIds.count+1` is the *less intuitive* reading the review flagged. **Recommended decision:** `N = (index of currentCard among non-done) + doneIds.count + 1` i.e. **count of cards already acted-on or currently in front of you** (cursor-position model), so skipping advances N. This is a one-line `ProgressInfo` choice — **flag to product, but implement the cursor model by default** and pin the exact N for a skip-then-advance sequence in a test so the choice is explicit and reversible. `M = workingOrder.count`.
  - **`[FIX-M2b]` `isComplete` infinite-skip trap:** do NOT define complete as "all done." Define **`isComplete = no card remains that is neither done nor skipped`** (every card acted on at least once), so a permanently-unshootable skipped card never traps the user. Additionally the UI must expose an **always-available exit** independent of `isComplete` `[FIX-M2b-ui]`.
  - **`[FIX-m1]` undo depth:** spec says "reverse last swipe" (singular). Implement **full LIFO stack** but this *exceeds spec* — keep, given the persistence-ordering fixes below make deep undo safe; pin chosen depth in a test. (If product rejects, cap at 1 — isolated to `undo()`.)
- Test: `ShootSessionTests.swift` (new) — initial order; markDone advance + N/M; skip-to-end + skippedCount + same-slot-surfaces-next; skipped re-surface & completable; `isComplete` only when none-pending-unacted; single-card & all-skipped edges; undo(done)/undo(skip) full reversal; multi-level LIFO to start; empty-stack no-op; **pinned N for skip-then-advance** `[FIX-M2a]`.

### A3. Outbox total ordering `[FIX-C2]` (CRITICAL — do before write path)
Files: `ios/PoseDeckCore/Sources/PoseDeckCore/Outbox.swift` (edit) + `SwiftDataOutbox.swift` (edit)
- Add a **monotonic sequence** to `OutboxEntry` (e.g. `var sequence: Int` or `UInt64`), assigned at enqueue time by the queue (InMemory: incrementing counter; SwiftData: max+1 or autoincrement column). Change `pending()` to sort by `(localTimestamp, sequence)` — a true total order so a `.create` always precedes a later `.update` for the same record even under an identical injected clock.
- Test: enqueue create-then-update with identical `now()`, assert `pending()` returns create first. (Lives in CardCompletionWritePathTests.)

### A4. MutationSender: duplicate-id → follow-up PATCH for completions `[FIX-C1]` + tighten detection `[FIX-m3]`
File: `ios/PoseDeckCore/Sources/PoseDeckCore/Sync/MutationSender.swift` (edit)
- **`[FIX-C1]`:** a create whose deterministic id already exists must NOT be a bare success when it carries a *new* state. Chosen approach (simplest robust): on a duplicate-id 400 for a `.create`, the sender performs a **follow-up PATCH** of `{state, changed_at}` to the existing record id, then returns `.success`. (For non-completion entities, keep existing bare-success behavior — gate the PATCH on `entity == "card_completions"`.) This closes the empty-mirror-but-server-row-exists data-loss race that backfill only *narrows*.
- **`[FIX-m3]`:** tighten `isDuplicateIdError` to inspect the validation **code** (`"validation_not_unique"`) rather than mere presence of `data.id`, so a format-error 400 drops **loudly** instead of masquerading as success.
- Tests: (a) server row=done, empty mirror, mark skipped → assert a PATCH is issued and final state=skipped (not dropped); (b) a `data.id` 400 with code `validation_invalid_value` → `.drop`, not `.success`.

### A5. `OfflineWritePath.markCardCompletion` + LWW tie bypass for own writes `[FIX-M1]`
Files: `OfflineWritePath.swift` (edit), `LocalStore.swift` (edit)
- Add `@discardableResult func markCardCompletion(cardId:userId:state:) async throws -> CardCompletion`:
  - id = `CardCompletion.deterministicId(card:user:)`; `changedAt = now()`.
  - **`[FIX-M1]` optimistic local write must not be a tie no-op.** Add a store method `applyLocalCardCompletion(_:)` (or a `force:` flag on upsert) that **bypasses the LWW tie guard for user-originated writes** — always applies the local user action. LWW stays intact for *incoming realtime echoes* (`SyncEngine` path unchanged). Then enqueue.
  - **Branch create-vs-update** on `store.cardCompletion(id:) == nil`: absent → `.create` (full body `{id,card,user,state,changed_at}`); present → `.update` PATCH `{id,state,changed_at}`. With `[FIX-C1]` the create path is now safe even when the mirror is wrong about server existence.
  - Each enqueue gets a fresh `idempotencyKey` (distinct state changes must both send); record id is the stable key, not the outbox key.
- Add wire bodies `CardCompletionUpsertWire` / `CardCompletionUpdateWire` (snake_case) in the wire-bodies section.
- Add to `LocalStore` protocol + `InMemoryLocalStore`: `func cardCompletions(cardIds:[String]) async -> [CardCompletion]` (filter by card-id set; deck-scoped read expressed via card ids since completions hold no deck relation) and the `[FIX-M1]` force-apply seam.
- Tests `CardCompletionWritePathTests.swift` (new): first mark → `.create` full body + optimistic mirror row written; second state flip same `(card,user)` → same id, `.update` PATCH; **`[FIX-M1]` markDone→undo→markDone under a constant injected clock ends local store = done** (tie bypass works); offline path issues NO network (only store+outbox); `cardCompletions(cardIds:)` returns the right subset.

### A6. Network `CardCompletionRepository` (for backfill/parity)
File: `ios/PoseDeckCore/Sources/PoseDeckCore/Repositories/CardCompletionRepository.swift` (new)
- Mirrors `DeckRepository`/`CardRepository`. `listCompletions(forUser:)` → `GET card_completions?filter=(user='...')` for backfill baseline. Optional `markDone/markSkipped` network variants for parity tests. This is the concrete fetch `SyncCoordinator.backfill` will call.

**Phase A gate:** `swift test` green (heavy majority of M4). Commit.

---

## PHASE B — App layer: plumbing, view model, view (compile + XCUITest-verifiable)

### B1. `cardCompletions(cardIds:)` in SwiftData store
File: `ios/PoseDeck/Sources/Sync/SwiftDataLocalStore.swift` (edit)
- Implement via `FetchDescriptor<LocalCardCompletion>` predicate `cardIds.contains($0.card)`, reuse existing row→model mapping. Implement the `[FIX-M1]` force-apply seam against `LocalCardCompletion`.

### B2. SyncCoordinator: backfill fetch + factory `[GAP-FIX]` + reinforces `[FIX-C1]`
File: `ios/PoseDeck/Sources/Sync/SyncCoordinator.swift` (edit)
- In `backfill(ownerId:)` (`:198`): construct `CardCompletionRepository(client: apiClient)`, fetch `listCompletions(forUser: ownerId)`, `upsertCardCompletion` each into the mirror (LWW baseline + prior progress on fresh launch / second device). This *narrows* the empty-mirror race but `[FIX-C1]` is what *closes* it.
- Add `func makeCardCompletionRepository() -> MirrorCardCompletionRepository` beside the existing factories (`:329-339`), matching the real `(store:outbox:)` ctor pattern.

### B3. Mirror completion repo
File: `ios/PoseDeck/Sources/Sync/MirrorRepositories.swift` (edit)
- `@MainActor struct MirrorCardCompletionRepository: CardCompletionRepositoring`, built with the **actual** mirror pattern (store+outbox; build its own `OfflineWritePath` internally as the other mirror repos do — NOT a `writePath/now` ctor, which doesn't exist). Reads → `store.cardCompletions(cardIds:)`. Writes → `writePath.markCardCompletion(...)`: `markDone`→`.done`, `markSkipped`→`.skipped`, `clearCompletion`→`.pending`.

### B4. App-facing protocol + fake
File: `ios/PoseDeck/Sources/Decks/CardCompletionRepositoring.swift` (new)
- `@MainActor protocol` mirroring `CardRepositoring`: `completions(forCardIds:userId:)`, `markDone`, `markSkipped`, `clearCompletion`. `FakeCardCompletionRepository` for previews/tests.

### B5. ShootModeViewModel
File: `ios/PoseDeck/Sources/Shoot/ShootModeViewModel.swift` (new)
- `@MainActor @Observable`. Owns `var session: ShootSession`, deck, repo, `userId`, image-URL cache.
- `onSwipeRight()/done()` → `session.markDone()` + `Task { try? await repo.markDone(...) }`.
- `onSwipeLeft()/skip()` → `session.skip()` + `repo.markSkipped(...)`.
- `onUndo()` → **read popped frame's cardId BEFORE undo** to know which card/state to reverse, then `session.undo()` + `repo.clearCompletion(reversedCardId,userId)` (persists `pending` so a second device converges via LWW — `[FIX-M6]` documents this is **STATE convergence only, never shoot ORDER**; order is always re-derived per-device from `card.position` + local skip history).
- Hydrate prior progress on load via `repo.completions(forCardIds:userId:)`, seeding `doneIds`/`skippedActiveIds`.
- **`[FIX-m2]` soft-delete-mid-shoot:** at write time, **skip persisting a completion for a card that is soft-deleted in the local mirror** (avoid orphan/zombie completion state). Document the "frozen snapshot ignores live deletions" choice.
- Exposes `currentCard`, `progressText` ("Card N of M"), `skippedCount`, `canUndo`, `isComplete`.

### B6. ShootModeView
File: `ios/PoseDeck/Sources/Shoot/ShootModeView.swift` (new)
- Read-only: image-prominent current card (title/time_slot/subjects/direction), DragGesture right=done/left=skip/up=expand sheet, large persistent top-left undo button (disabled when `!canUndo`), top-center progress, "+K skipped" badge when `skippedCount>0`, `isComplete` end state, **plus an always-available exit affordance `[FIX-M2b-ui]`** independent of `isComplete`.
- **CI hook:** hidden / `.accessibilityAction` controls `shoot.action.done` / `.skip` / `.undo` calling the **same** view-model methods as gestures. Accessibility ids: `shoot.card-image`, `shoot.card-title`, `shoot.progress`, `shoot.skipped-count`, `shoot.undo-button`, `shoot.complete`, `shoot.exit`, + the three action ids.

### B7. DeckDetailView entry
File: `ios/PoseDeck/Sources/Decks/DeckDetailView.swift` (edit)
- "Start shoot" toolbar/header button, id `deck.startShoot`, shown only when `!model.isEmpty`. Pushes `ShootModeView` via `navigationDestination`, built by injected `shootModeFactory: (Deck,[Card]) -> AnyView` (same pattern as `cardEditorFactory`). Pass current cards snapshot.

### B8. RootView wiring
File: `ios/PoseDeck/Sources/RootView.swift` (edit)
- In `makeDetail(deck:ownerId:)`, build `shootModeFactory` → `ShootModeView(ShootModeViewModel(deck:cards:completionRepo: sync.makeCardCompletionRepository(), imageRepo: sync.makeImageRepository(), userId: ownerId))`. Wire into DeckDetailView's new param.

---

## PHASE C — iOS gauntlet (XCUITest + compile-check; invoke `milestone-gauntlet-ios`)

### C1. XCUITest
File: `ios/PoseDeck/UITests/ShootModeUITests.swift` (new)
- Extends `PoseDeckUITestCase`: signIn → create deck + 3 cards → open deck → tap `deck.startShoot` → assert `shoot.card-image` + `shoot.progress` == "Card 1 of 3". Tap `shoot.action.done` → progress advances. Tap `shoot.action.skip` → `shoot.skipped-count` "+1 skipped". Tap `shoot.action.undo` → skip reversed. Act on all → `shoot.complete`. **Drives via accessibility-action buttons only — never raw swipe physics.**

### C2. Verification split (matches iOS gauntlet ownership)
- **`swift test`** (deterministic bulk): ShootSession, write-path (incl. all FIX regression tests A3/A4/A5), `cardCompletions(cardIds:)`, deterministicId shape.
- **`xcodebuild` compile-check**: ShootModeView/ViewModel + DeckDetailView entry + RootView wiring compile (in lieu of runnable e2e — simulator flaky per M2 memory).
- **Optional live-PB integration** (gated like existing 8): mark done vs `localhost:8090`, assert composite-unique holds and re-create same `(card,user)` is idempotent / patches not duplicates.
- **DEV/DEVICE-ONLY (not CI):** swipe FEEL — drag thresholds, right/left/up directional disambiguation, inter-card + "fly to end" animation, swipe-up expand sheet + dismiss, undo-button ergonomics. The accessibility-action buttons are the CI surrogate for the LOGIC; physics is hand-verified.

### C3. Commit per gauntlet cadence
- Commit at Phase A green, again after Phase B compiles, final after gauntlet green. Never push unless asked.

---

## Critical/major fixes folded in (traceability)

| Tag | Severity | Fix location | What changed vs original design |
|---|---|---|---|
| C1 | critical | A4 MutationSender + A5 branch | Duplicate-id create no longer bare success for completions → follow-up PATCH; closes empty-mirror/server-row-exists silent data loss (backfill alone insufficient) |
| C2 | critical | A3 Outbox | Added monotonic `sequence`; `pending()` sorts `(timestamp,sequence)` → PATCH can't precede its CREATE under equal clock |
| M1 | major | A5 + B1 store seam | User-originated optimistic writes bypass LWW tie-skip; LWW kept for incoming echoes only → done→undo→done same-tick no longer no-ops local |
| M2a | major | A2 ProgressInfo | "Card N of M" = cursor-position model (skips advance N), test-pinned; flag to product |
| M2b | major | A2 + B6 | `isComplete` = "no card neither-done-nor-skipped" (no infinite-skip trap) + always-available `shoot.exit` |
| M6 | major | B5 + doc | Cross-device sync = completion STATE only, not ephemeral shoot ORDER; tighten "converges" wording; test asserts no position/reorder writes during shoot |
| m1 | minor | A2 | Full LIFO undo exceeds "reverse last swipe" — kept (now safe post C1/C2), depth test-pinned; cap-at-1 fallback isolated to `undo()` |
| m2 | minor | B5 | Don't persist completions for cards soft-deleted in mirror at write time (no zombie progress) |
| m3 | minor | A1 + A4 | deterministicId via IDGenerator charset (`^[a-z0-9]{15}$`, tested); `isDuplicateIdError` checks `validation_not_unique` so format-error 400 drops loudly |

## Correction to the brief
The brief states M3 deferred `card_completions` **realtime consumption** and "it must land here." **This is inaccurate** — realtime consumption is already wired and LWW-merged in M3 (`RealtimeClient.swift:189`, `SyncEngine.swift:80-81,167-171`). M4 adds only: the **write path**, the **`cardCompletions(cardIds:)` read**, and the **backfill fetch**. Do not duplicate realtime handling.

## Sequencing rule
Do **A3 + A4 (the two critical ordering/idempotency fixes) before A5 (the write path)**, and A5 before any app wiring. The review verdict is explicit: do not proceed to write-path implementation until create/update ordering and the deterministic-id-vs-duplicate-success interaction are fixed with regression tests.

Relevant files (absolute):
- New: `/Users/qthienng/projects/pose-deck/ios/PoseDeckCore/Sources/PoseDeckCore/Shoot/ShootSession.swift`, `/Users/qthienng/projects/pose-deck/ios/PoseDeckCore/Sources/PoseDeckCore/Repositories/CardCompletionRepository.swift`, `/Users/qthienng/projects/pose-deck/ios/PoseDeck/Sources/Decks/CardCompletionRepositoring.swift`, `/Users/qthienng/projects/pose-deck/ios/PoseDeck/Sources/Shoot/ShootModeViewModel.swift`, `/Users/qthienng/projects/pose-deck/ios/PoseDeck/Sources/Shoot/ShootModeView.swift`, plus tests `/Users/qthienng/projects/pose-deck/ios/PoseDeckCore/Tests/PoseDeckCoreTests/ShootSessionTests.swift`, `/Users/qthienng/projects/pose-deck/ios/PoseDeckCore/Tests/PoseDeckCoreTests/CardCompletionWritePathTests.swift`, `/Users/qthienng/projects/pose-deck/ios/PoseDeck/UITests/ShootModeUITests.swift`
- Edit: `/Users/qthienng/projects/pose-deck/ios/PoseDeckCore/Sources/PoseDeckCore/Models/CardCompletion.swift`, `/Users/qthienng/projects/pose-deck/ios/PoseDeckCore/Sources/PoseDeckCore/Outbox.swift`, `/Users/qthienng/projects/pose-deck/ios/PoseDeckCore/Sources/PoseDeckCore/Sync/MutationSender.swift`, `/Users/qthienng/projects/pose-deck/ios/PoseDeckCore/Sources/PoseDeckCore/Sync/OfflineWritePath.swift`, `/Users/qthienng/projects/pose-deck/ios/PoseDeckCore/Sources/PoseDeckCore/Sync/LocalStore.swift`, `/Users/qthienng/projects/pose-deck/ios/PoseDeck/Sources/Sync/SwiftDataLocalStore.swift`, `/Users/qthienng/projects/pose-deck/ios/PoseDeck/Sources/Sync/SwiftDataOutbox.swift`, `/Users/qthienng/projects/pose-deck/ios/PoseDeck/Sources/Sync/SyncCoordinator.swift`, `/Users/qthienng/projects/pose-deck/ios/PoseDeck/Sources/Sync/MirrorRepositories.swift`, `/Users/qthienng/projects/pose-deck/ios/PoseDeck/Sources/Decks/DeckDetailView.swift`, `/Users/qthienng/projects/pose-deck/ios/PoseDeck/Sources/RootView.swift`
