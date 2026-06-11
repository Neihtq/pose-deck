import Foundation

/// Pure, deterministic state machine for an iOS shoot session (DESIGN.md §4.2).
///
/// A `ShootSession` models the *order and progress* of working through a deck's
/// cards with swipe gestures — right = done, left = skip-to-end — plus a full
/// undo history. It performs **no I/O, holds no clock, and touches no store**:
/// it is a value type the view model drives, mirroring each transition to the
/// persistence layer separately. That keeps every ordering decision exhaustively
/// unit-testable and the persistence path (LWW completions) cleanly decoupled.
///
/// Shoot **order is per-device and ephemeral**: it is re-derived on every launch
/// from `card.position` plus the local skip history, and is never synced. Only
/// completion **state** (done/skipped/pending) crosses devices — see the M4
/// plan `[FIX-M6]`. This type therefore deals purely in card ids and never
/// reads or writes a network or a clock.
public struct ShootSession: Sendable, Equatable {

    /// A single reversible transition recorded for undo (`[FIX-m1]`: a full LIFO
    /// stack, exceeding the spec's "reverse last swipe", which is kept because the
    /// persistence ordering fixes make deep undo safe).
    public enum UndoFrame: Sendable, Equatable {
        /// The card was marked done from cursor `fromIndex`.
        case done(cardId: String, fromIndex: Int)
        /// The card at `fromIndex` was skipped and moved to `movedToIndex`.
        case skip(cardId: String, fromIndex: Int, movedToIndex: Int)
    }

    /// The working order of card ids. Initialised to the deck's non-soft-deleted
    /// cards in `position` order; done cards stay in place, skipped cards move to
    /// the end.
    public private(set) var workingOrder: [String]
    /// The original, position-sorted card ids the session was built from, captured
    /// directly from the constructor parameter before any mutation. Used by
    /// ``reset()`` to restore a finished session to its starting order so the deck
    /// can be re-shot (item 3); never derived from `workingOrder`, which `skip()`
    /// reorders (`[M-reset]`).
    public private(set) var originalOrder: [String]
    /// Cursor into `workingOrder`. `currentCardId` is the first id at/after this
    /// index that is not yet done.
    public private(set) var index: Int
    /// Cards marked done.
    public private(set) var doneIds: Set<String>
    /// Cards that have been skipped at least once (still "acted on", so they no
    /// longer trap completion — see ``isComplete``).
    public private(set) var skippedActiveIds: Set<String>
    /// LIFO history of transitions for ``undo()``.
    public private(set) var undoStack: [UndoFrame]

    /// Build a session from the ordered (already filtered) card ids.
    ///
    /// The caller passes the non-soft-deleted cards in `position` order; this is a
    /// frozen snapshot — live deletions/additions during the shoot are ignored by
    /// design (DESIGN.md §4.2: shoot mode is read-only in v1).
    public init(cardIds: [String]) {
        self.workingOrder = cardIds
        self.originalOrder = cardIds
        self.index = 0
        self.doneIds = []
        self.skippedActiveIds = []
        self.undoStack = []
    }

    /// Build a session hydrated from prior completion **state** (done/skipped),
    /// re-deriving the per-device working order from the supplied position-sorted
    /// card ids (`[FIX-M6]`: order is never synced — only state crosses devices).
    ///
    /// Hydrated state seeds no undo history (a prior-session completion is not a
    /// reversible in-session transition) and leaves the cursor at the start; the
    /// derived `currentCardId` skips over already-done cards. Ids in
    /// `doneIds`/`skippedActiveIds` that are not in `cardIds` are ignored.
    public init(cardIds: [String], doneIds: Set<String>, skippedActiveIds: Set<String>) {
        let present = Set(cardIds)
        self.workingOrder = cardIds
        self.originalOrder = cardIds
        self.index = 0
        self.doneIds = doneIds.intersection(present)
        self.skippedActiveIds = skippedActiveIds.intersection(present)
        self.undoStack = []
    }

    // MARK: - Derived state

    /// The id of the card currently presented, or `nil` when the session is
    /// complete. The cursor skips over already-done cards still sitting in
    /// `workingOrder`.
    public var currentCardId: String? {
        guard index < workingOrder.count else { return nil }
        var i = index
        while i < workingOrder.count {
            let id = workingOrder[i]
            if !doneIds.contains(id) { return id }
            i += 1
        }
        return nil
    }

    /// `true` only once every card has been marked **done**.
    ///
    /// `[FIX-skip-resurface]`: a *skipped* card is not "finished" — skip means
    /// "come back to this later", so a skipped-but-not-done card keeps the session
    /// going and re-surfaces at the end of the working order (``skip()`` appends
    /// it). The deck therefore loops back to skipped cards after the last card
    /// instead of declaring completion early. The user is never trapped: the shoot
    /// screen always offers an exit (top-right close), independent of this flag.
    ///
    /// (Supersedes the old `[FIX-M2b]` "acted-on = complete" rule, which ended the
    /// shoot while skipped cards were still outstanding and so never re-surfaced
    /// them — the reported skip bug.)
    public var isComplete: Bool {
        workingOrder.allSatisfy { doneIds.contains($0) }
    }

    /// Number of cards skipped and not since marked done.
    public var skippedCount: Int {
        skippedActiveIds.subtracting(doneIds).count
    }

    /// Whether ``undo()`` would do anything.
    public var canUndo: Bool { !undoStack.isEmpty }

    /// Progress for the "Card N of M" indicator (DESIGN.md §4.2).
    ///
    /// `[FIX-M2a]` **cursor-position model** (test-pinned): `position` counts how
    /// far through the deck the current card sits — every card at-or-before the
    /// cursor (done *or* skipped-ahead survivor) plus 1 for the current card — so a
    /// **skip advances N** (you have moved forward in the deck even though the card
    /// returns later). `total` = `workingOrder.count`. When complete, `position`
    /// equals `total`.
    ///
    /// `[FIX-CORR-1]`: count only done cards **at-or-before the cursor**, not all
    /// done cards. A done card sitting *ahead* of the cursor (the normal hydrated
    /// shape from `init(cardIds:doneIds:…)`, which leaves done cards in position
    /// order) has not been passed yet, so it must not inflate N. Previously the
    /// first card of a hydrated session with a later done card could read e.g.
    /// "Card 2 of 3", reporting progress past the card actually shown.
    public var progress: (position: Int, total: Int) {
        let total = workingOrder.count
        guard let current = currentCardId,
              let currentIdx = workingOrder.firstIndex(of: current) else {
            return (total, total)
        }
        // Every card strictly before the cursor has been passed (it is either done
        // or a skipped-ahead survivor), so count them all + 1 for the current card.
        // Done cards positioned *after* the cursor are not yet reached.
        let position = currentIdx + 1
        return (position, total)
    }

    // MARK: - Transitions

    /// Mark the current card done and advance the cursor. No-op when complete.
    public mutating func markDone() {
        guard let current = currentCardId,
              let currentIdx = workingOrder.firstIndex(of: current) else { return }
        undoStack.append(.done(cardId: current, fromIndex: index))
        doneIds.insert(current)
        // A re-surfaced previously-skipped card that's now done is still "acted
        // on" via done; leave skippedActiveIds as-is (subtracted out of skippedCount).
        index = currentIdx + 1
    }

    /// Skip the current card: move it to the end of the working order. The cursor
    /// stays put so the next card slides into the current slot. No-op when complete.
    public mutating func skip() {
        guard let current = currentCardId,
              let currentIdx = workingOrder.firstIndex(of: current) else { return }
        workingOrder.remove(at: currentIdx)
        let movedTo = workingOrder.count // appended at the end
        workingOrder.append(current)
        skippedActiveIds.insert(current)
        undoStack.append(.skip(cardId: current, fromIndex: currentIdx, movedToIndex: movedTo))
        // Cursor unchanged: the next card now occupies `currentIdx`. If the cursor
        // had advanced past done cards we keep `index` where it was; currentCardId
        // re-derives the next presentable card.
        index = currentIdx
    }

    /// Reverse the most recent transition (LIFO). No-op on an empty stack.
    ///
    /// Fully reverses order, cursor, and sets:
    ///  - un-done: remove from `doneIds`, restore the cursor to `fromIndex`.
    ///  - un-skip: move the card from the end back to `fromIndex` and restore the
    ///    cursor to `fromIndex`. If the same card had not been skipped elsewhere
    ///    in the remaining history, drop it from `skippedActiveIds`.
    public mutating func undo() {
        guard let frame = undoStack.popLast() else { return }
        switch frame {
        case let .done(cardId, fromIndex):
            doneIds.remove(cardId)
            index = fromIndex
        case let .skip(cardId, fromIndex, _):
            // Remove the card from wherever it now sits (the end) and reinsert it
            // at its original slot.
            if let nowAt = workingOrder.firstIndex(of: cardId) {
                workingOrder.remove(at: nowAt)
            }
            let insertAt = min(fromIndex, workingOrder.count)
            workingOrder.insert(cardId, at: insertAt)
            // Only clear the skipped flag if no earlier-and-still-present skip of
            // the same card remains in the history.
            let stillSkippedLater = undoStack.contains { if case let .skip(c, _, _) = $0 { return c == cardId } else { return false } }
            if !stillSkippedLater {
                skippedActiveIds.remove(cardId)
            }
            index = fromIndex
        }
    }

    /// The presentable upcoming cards — every not-yet-done id from the cursor
    /// onward, in working order. This is exactly what an in-shoot overview lists
    /// and what ``reorderUpcoming(_:)`` accepts a permutation of. The current
    /// card is the first element (or empty when complete).
    public var upcomingIds: [String] {
        guard index < workingOrder.count else { return [] }
        return workingOrder[index...].filter { !doneIds.contains($0) }
    }

    /// Reorder the upcoming (not-yet-done) cards in place — the live "shoot this
    /// next" decision an in-shoot overview offers (item 5). Reorder is **session
    /// scoped and ephemeral**, exactly like the rest of the working order: it is
    /// never persisted or synced (the deck-prep screen owns durable reordering).
    ///
    /// `newOrder` must be a permutation of ``upcomingIds`` — any id added,
    /// dropped, or duplicated makes the call a **no-op**, so a stale overview can
    /// never corrupt the session (total count and cursor are preserved). Done
    /// cards sitting ahead of the cursor (the hydrated shape) keep their slots;
    /// only the not-done ids are repositioned. This does **not** push an undo
    /// frame: Undo reverses the last *swipe*, not a reorder, and undo locates its
    /// card by id + reinserts before the cursor, so a suffix reorder leaves the
    /// existing undo history valid.
    public mutating func reorderUpcoming(_ newOrder: [String]) {
        guard index <= workingOrder.count else { return }
        let suffix = Array(workingOrder[index...])
        let notDone = suffix.filter { !doneIds.contains($0) }
        // Permutation guard: same membership AND same count (rejects dupes).
        guard newOrder.count == notDone.count, Set(newOrder) == Set(notDone) else {
            return
        }
        // Walk the original suffix; refill each not-done slot from `newOrder` in
        // order, leaving any done-ahead ids pinned to their positions.
        var feed = newOrder.makeIterator()
        let rebuiltSuffix = suffix.map { id in
            doneIds.contains(id) ? id : (feed.next() ?? id)
        }
        workingOrder = Array(workingOrder[..<index]) + rebuiltSuffix
    }

    /// Restore the session to its starting state so the deck can be re-shot
    /// (item 3): the working order returns to ``originalOrder`` (undoing any
    /// `skip()` reorders), the cursor returns to the start, and all progress
    /// (done/skipped) plus the undo history is cleared. The result is identical to
    /// a fresh `init(cardIds:)` with the original ids.
    public mutating func reset() {
        workingOrder = originalOrder
        index = 0
        doneIds = []
        skippedActiveIds = []
        undoStack = []
    }
}
