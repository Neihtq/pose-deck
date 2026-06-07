# 6 UX/iOS Fixes — Implementation Plan (vetted via design+adversarial-review 2026-06-07)

All adversarial claims confirmed against actual code. `resetCompletions` doesn't exist yet, core `DeckRepository.init` is `(client:, now:)` with no image dep, and `MirrorRepositories.swift:330` shows `FakeImageRepository`/image repo already constructed with `remote: ImageRepository` — useful for the Stream B wiring. I have enough verified ground truth. Here is the consolidated plan.

---

# Pose Deck — Consolidated Implementation Plan (6 fixes, 2 streams)

All 11 adversarial findings (3 critical, 6 major, 2 minor) are folded in below; each is tagged `[Cxx]` / `[Mxx]` / `[mxx]` at the point it changes the design. Ground-truth verified: ShootModeUITests.swift:78 taps `shoot.action.undo`; action hooks at ShootModeView.swift:220-222 are Skip/Undo/Done; ShootSession has no `originalOrder`; core `DeckRepository.init(client:, now:)` has no image dep; `resetCompletions` does not exist anywhere; web detail tests live in `web/src/features/decks/__tests__/`; `DeckDetailPageOwnerGating.test.tsx` asserts Duplicate present.

## Stream independence
- **Stream A** = shoot mode (items 2, 3, 5, 6): `ShootModeView`, `ShootModeViewModel`, `ShootSession`, `CardCompletionRepositoring`, plus `resetCompletions` in `MirrorRepositories` and `PreviewFakes`.
- **Stream B** = duplicate + paste (items 1, 4): `CardImagesSection`, core `DeckRepository`, `MirrorDeckRepository.duplicateDeck` (image copy), `DeckDetailView`, web `DeckDetailPage.tsx` + `deckApi.ts`, `PreviewFakes` (image-copy collaborator).
- **Conflict point — `MirrorRepositories.swift` and `PreviewFakes.swift` are touched by BOTH streams.** Stream A adds `resetCompletions` (a completion-repo method); Stream B adds image-copy to `duplicateDeck` (a deck-repo method) — different types/methods in the same files. Land **Stream A first**, then Stream B rebases. Keep each stream's edits in non-adjacent regions; resolve the two shared files by sequencing, not parallel edits.

---

## STREAM A — shoot mode (items 2, 3, 5, 6)

Order is bottom-up: pure model → repo protocol → view model → view → tests.

### A1. ShootSession.reset (item 3, pure) — `ShootSession.swift`
- Add stored `public private(set) var originalOrder: [String]`.
- **[M-reset]** In BOTH inits set `self.originalOrder = cardIds` **directly from the constructor parameter**, before any mutation (value-type copy; never derive from `workingOrder`, which `skip()` mutates at lines 155-157).
- Add `public mutating func reset()`: `workingOrder = originalOrder; index = 0; doneIds = []; skippedActiveIds = []; undoStack = []`.
- **swift test (CI-verifiable):** build session, `skip()` card A (moves to end), `markDone()` B, `reset()`; assert `workingOrder == originalOrder` (A back in original slot), `currentCardId == originalOrder.first`, `isComplete == false`, `canUndo == false`, `progress == (1, total)`; and a reset session `==` a fresh `init(cardIds:)`.

### A2. resetCompletions on the completion protocol (item 3) — `CardCompletionRepositoring.swift`
- Add `func resetCompletions(forCardIds:[String], userId:String) async throws` to the protocol.
- **[M-scope]** Caller passes the **union of `session.doneIds ∪ session.skippedActiveIds ∪ ids-present-in-the-prior-completions-fetch`**, NOT all deck ids — avoids fabricating pending rows for never-touched cards while still clearing cross-device done state. (Decision: scope it; do not pass all ids.)
- Fake impl: loop `upsert(pending)` over the supplied ids.

### A3. Mirror resetCompletions (item 3) — `MirrorRepositories.swift` (Stream-A region only)
- Implement `resetCompletions` by looping `markCardCompletion(..., .pending)` per id (deterministic id keyed on card+user, LWW/`changed_at`-convergent, coalesces; loop because there's no bulk write). `applyLocalCardCompletion` updates the local mirror synchronously per call.

### A4. ShootModeViewModel.reshoot (item 3) — `ShootModeViewModel.swift`
- Add `reshoot()`: `session.reset()` → `await` the scoped `resetCompletions` (A2) so the **local mirror is reset synchronously** before any hydration path can re-read → prefetch. **Never call `load()`.**
- **[M-hydrate]** Keep `didHydrate = true` across reshoot. Additionally, because a re-entered shoot screen may construct a fresh view model (`didHydrate` resets to false), `reshoot` must `await` the mirror reset (not just schedule it) so even a fresh `load()` reads `pending`. Add a guard test (below) for the fresh-instance path.

### A5. ShootModeView — swipe + single control bar (items 2, 5, 6) — `ShootModeView.swift`
- **Control bar (items 5+6):** delete the in-card `hintBar` (123-133) and the `actionHooks` overlay (lines 220-222). Add ONE `.safeAreaInset(edge: .bottom)` control bar on the root so the card lays out above it.
  - **[m-bar]** Three bordered labeled buttons: **Skip** `arrow.left` id `shoot.action.skip`; **Details** `arrow.up` (sets the SAME `$showDetailSheet` binding the swipe-up uses — not a separate sheet) id `shoot.action.details`; **Done** `checkmark` id `shoot.action.done`. Keep top-left Undo `shoot.undo-button` and exit `shoot.exit`. Bar lives in the inset, outside the card's `.offset(dragOffset)`/`.gesture` region.
  - **[C1] Undo id resolution (CRITICAL):** ShootModeUITests.swift:78 taps `shoot.action.undo`, which the old `actionHooks` provided. **Decision: keep an Undo affordance with id `shoot.action.undo` in the new control bar** (4 buttons: Skip / Undo / Details / Done — Undo gated on `model.canUndo`, calls `model.undo()`), so the e2e test's tap target survives. This is the lowest-churn fix and keeps the top-left `shoot.undo-button` as the primary undo. Do NOT remove the id. Re-grep after editing to confirm only line 78 (tap) and line 6 (doc) reference it.
- **Swipe (item 2):** add rotation (~12°) + scale + spring-back under threshold; on commit, fly-off then advance.
  - **[M-flyoff]** Decouple exit animation from the model mutation: add `.id(session.currentCardId)` to the card so each card has fresh `@State dragOffset`; either call `model.done()/skip()` **inside `withAnimation`** so the content swap is one transaction, or animate a departing-card overlay/asymmetric `.transition` and call `done()/skip()` on completion, resetting `dragOffset = .zero` in the same transaction that swaps cards (no jump). The button path (`model.done()/skip()` directly, `dragOffset == .zero`) must advance with zero dependence on animation completion.
  - **[m-bar] Small-device:** verify iPhone SE — card `maxHeight:420` + title + meta + reserved inset must not clip; bar buttons hittable.
- **completeState:** add reshoot button id `shoot.reshoot` calling `model.reshoot()`.

### A6. PreviewFakes (Stream-A portion) — `PreviewFakes.swift`
- Update fakes for `resetCompletions` so previews/tests compile.

### A7. Stream-A tests
- **swift test (CI-verifiable):** ShootSession.reset cases (A1); reshoot on a 3-card deck where only 1 was done enqueues exactly the needed writes and the mirror converges all to `pending` (M-scope); hydrate-with-done → reshoot → call `load()` again → assert session stays reset (M-hydrate); fresh-view-model-instance hydration reads `pending` from the mirror.
- **XCUITest (device/simulator-only, NOT CI per verification-ownership — simulator broken; compile-check only in CI):** control-bar ids `shoot.action.skip/.done/.details/.undo` + `shoot.undo-button`/`shoot.exit` exist, hittable, no overlap; skip/done advance progress; details opens the sheet; `shoot.reshoot` to complete then back to "Card 1" with skipped badge cleared; guard that a later `load()` does not re-mark done. **The existing ShootModeUITests.swift:78 path is preserved by [C1] — no test edit needed.**

---

## STREAM B — duplicate + paste (items 1, 4)

### B1. CardImagesSection paste (item 1) — `CardImagesSection.swift`
- Add `handlePasted(data:)` that reuses `addImage` (so `ImageUploadGate` busy/atLimit/allowed, compressor, and cap are all enforced — mirrors web `inFlight`).
- **[m-paste]** Use SwiftUI `PasteButton(supportedContentTypes: [.image])` (iOS 16+; system auto-disables when no image on clipboard) beside `PhotosPicker`; in the handler take the first item, convert `UIImage → jpegData` if needed (compressor expects encodable Data), call `model.handlePasted(data:)`. Also `.disabled(model.atImageLimit || model.isUploading)` to match `cardImages.add`. id `cardImages.paste`.
- **Test:** unit/UI assertion that pasting a non-image clipboard is a no-op (no toast, no upload) and pasting at the 5-image cap surfaces the "at most 5 images" message without exceeding the cap.

### B2. Web duplicate — remove from detail menu + fix tests (item 4, CRITICAL) 
- `web/src/features/decks/DeckDetailPage.tsx`: remove the Duplicate menu item, `handleDuplicate` (~line 265), and the now-unused import. **Keep Duplicate in the deck LIST** (`DeckListPage.tsx`/`DeckCard.tsx`).
- **[C3] Test breakage (CRITICAL):** `web/src/features/decks/__tests__/DeckDetailPageOwnerGating.test.tsx` asserts Duplicate IS present for owners (and a guest case). In the SAME commit: drop the Duplicate expectation, rename the test to "shows Share/Rename/Delete". Audit `DeckDetailPage.test.tsx` and `DeckDetailA11y.test.tsx` for any Duplicate-in-detail assertion or unused `duplicateDeck` mock and clean them so the suites compile.

### B3. Web duplicate image-copy — online-only deferred (item 4, CRITICAL) — `deckApi.ts`
- **[C2] Infeasibility fix (CRITICAL):** the offline-first `duplicateDeck` enqueues outbox `create`s; the copy card does not exist server-side at duplicate time, and `uploadCardImage` (imageApi.ts:41) is synchronous PB-direct, and `imageDisplayUrl`/token mint is network-bound. **Decision: image-copy is a best-effort ONLINE-only post-step.** Gate the entire image-copy behind `navigator.onLine`; run it only AFTER the copy cards' outbox `create`s have flushed (await sync drain / verify the copy card exists server-side) — then per source image: `imageDisplayUrl → blob → uploadCardImage(copyCardId)`. Each image in try/catch: log and continue; never block or fail the duplicate itself (cards exist regardless). Cap respected (`uploadCardImage` already throws `TooManyImagesError` — catch per-image). Document: on web, duplicated images appear only after the copy cards have synced; offline → cards copy, images skipped cleanly.
- **vitest (CI-verifiable):** `duplicateDeck` copies images with source position + new id; a single rejection logs and continues; cap respected; offline → no upload attempted, duplicate still succeeds; `DeckDetailPage` has no Duplicate; list keeps it.

### B4. iOS duplicate image-copy (item 4) — core `DeckRepository.swift` + `MirrorRepositories.swift` (Stream-B region) + `DeckDetailView.swift` + `PreviewFakes.swift`
- **[M-wiring]** Core `DeckRepository.init` is `(client:, now:)` with zero image refs; `MirrorDeckRepository.init` is `(store:, outbox:, currentUserId:, now:)`. Before editing, **enumerate every `DeckRepository(...)` / `MirrorDeckRepository(...)` call site + `DeckRepositoryTests`.** Inject `ImageRepositing` as a **defaulted/optional** parameter to avoid breaking existing tests; otherwise update all call sites in the same change. (Note: `MirrorRepositories.swift:330` already constructs an image repo with `remote: ImageRepository`, so the collaborator is locally available.)
- Per source card, after the copy card is created: list source images by position, mint token URL via `ImageRepository.fileURL(for:)`, download bytes via **`ProtectedImageSession.make()`** (per SEC-IOS-B: private bytes must not hit `URLCache.shared` — NOT `URLSession.shared`), `uploadCardImage` at source position (already-compressed JPEG). Best-effort: per-image try/catch, log and continue, never abort; per-image token mint bounds expiry; cap 5 re-checked.
- `DeckDetailView.swift`: remove Duplicate from the deck-actions Menu (keep on list).
- `PreviewFakes.FakeDeckRepository.duplicateDeck`: update for the image-copy collaborator so it does not silently diverge (today it just appends a renamed Deck, copies nothing) and so previews/tests compile.

### B5. Stream-B tests
- **swift test (CI-verifiable):** core `DeckRepository.duplicateDeck` copies images per card best-effort; per-image failure continues; cap honored; `FakeDeckRepository` updated. **device-only:** actual ProtectedImageSession download path.
- **vitest (CI):** per B3.

---

## Regression gates (keep green)
- iOS: `swift test` (PoseDeckCore unit) + live-PB integration; `xcodebuild` app compile-check (simulator/XCUITest are device-only per verification-ownership — not CI).
- Web: `vitest` + e2e.
- Run the full milestone-gauntlet after both streams land.

## CI-verifiable vs device-only
- **CI:** all swift unit tests (ShootSession.reset, reshoot scoping/hydration, core duplicateDeck image-copy with fakes), all web vitest, app compile-check.
- **Device-only (manual):** every XCUITest (control-bar ids/hittability/no-overlap, swipe fly-off feel, paste UI, iPhone SE layout) and the real `ProtectedImageSession` image download on iOS.

## Critical sequencing
1. Land **Stream A** first (it owns the shared-file additions that are pure-additive).
2. **[C1]** keep `shoot.action.undo` in the new control bar — bundle with the bar rewrite; re-grep.
3. **[C3]** edit `DeckDetailPageOwnerGating.test.tsx` (+ audit the other two detail tests) in the **same commit** as the web menu removal (B2).
4. **[C2]** web image-copy ships only as the online-only post-drain step (B3) — never synchronous in the offline-first duplicate.
5. Then **Stream B** rebases onto A; resolve `MirrorRepositories.swift` / `PreviewFakes.swift` by region (A=completion/reset, B=deck/image), not parallel edits.

Verified files of note (absolute): `/Users/qthienng/projects/pose-deck/ios/PoseDeck/UITests/ShootModeUITests.swift` (undo tap line 78; hooks 220-222 in view), `/Users/qthienng/projects/pose-deck/ios/PoseDeckCore/Sources/PoseDeckCore/Shoot/ShootSession.swift` (no originalOrder; skip mutates workingOrder 155-157), `/Users/qthienng/projects/pose-deck/ios/PoseDeckCore/Sources/PoseDeckCore/Repositories/DeckRepository.swift` (init line 30, no image dep), `/Users/qthienng/projects/pose-deck/ios/PoseDeck/Sources/Sync/MirrorRepositories.swift` (inits 34/177/216/285; image repo at 330), `/Users/qthienng/projects/pose-deck/web/src/features/decks/__tests__/DeckDetailPageOwnerGating.test.tsx` (asserts Duplicate present), `/Users/qthienng/projects/pose-deck/web/src/features/decks/deckApi.ts` + `imageApi.ts` (offline-first vs PB-direct).
