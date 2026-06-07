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
        self.index = 0
        self.doneIds = []
        self.skippedActiveIds = []
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

    /// `true` once every card has been acted on at least once (done *or* skipped).
    ///
    /// `[FIX-M2b]`: completion is deliberately **not** "all done" — a card that is
    /// never shootable could otherwise trap the user in an infinite skip loop.
    /// Once every card has been swiped at least once, the session is complete
    /// (the UI still offers an always-available exit independent of this, handled
    /// in the app layer `[FIX-M2b-ui]`).
    public var isComplete: Bool {
        workingOrder.allSatisfy { doneIds.contains($0) || skippedActiveIds.contains($0) }
    }

    /// Number of cards skipped and not since marked done.
    public var skippedCount: Int {
        skippedActiveIds.subtracting(doneIds).count
    }

    /// Whether ``undo()`` would do anything.
    public var canUndo: Bool { !undoStack.isEmpty }

    /// Progress for the "Card N of M" indicator (DESIGN.md §4.2).
    ///
    /// `[FIX-M2a]` **cursor-position model** (test-pinned): `position` counts the
    /// cards already acted-on or currently in front of you — i.e. done cards plus
    /// the count of not-yet-done cards ahead of the current one — so a **skip
    /// advances N** (you have moved forward in the deck even though the card
    /// returns later). `total` = `workingOrder.count`. When complete, `position`
    /// equals `total`.
    public var progress: (position: Int, total: Int) {
        let total = workingOrder.count
        guard let current = currentCardId,
              let currentIdx = workingOrder.firstIndex(of: current) else {
            return (total, total)
        }
        // Non-done cards strictly before the cursor (skipped-ahead survivors) +
        // all done cards + 1 for the current card.
        let nonDoneBefore = workingOrder[0..<currentIdx].filter { !doneIds.contains($0) }.count
        let position = nonDoneBefore + doneIds.count + 1
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
}
