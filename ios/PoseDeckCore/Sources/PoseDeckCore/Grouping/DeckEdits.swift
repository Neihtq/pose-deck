import Foundation

/// Pure decision helpers for deck-level edits (rename / set date).
///
/// Side-effect free and deterministic so the "should we issue a write?" logic
/// stays fully unit-testable, independent of the (app-target) view models that
/// call it. Mirrors the web reference guards (`DeckDetailPage.handleRename`
/// returns early when `next === deck.name`).
public enum DeckEdits {

    /// The trimmed name to persist for a rename, or `nil` when the rename should
    /// be skipped entirely.
    ///
    /// Returns `nil` when the proposed name is empty after trimming, or when it
    /// is unchanged from `current`. Returning `nil` for a no-op rename prevents a
    /// needless `client_updated_at` re-stamp that could clobber a concurrent edit
    /// under last-write-wins (ARCHITECTURE.md §4.3).
    public static func renameTarget(proposed: String, current: String) -> String? {
        let trimmed = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != current else { return nil }
        return trimmed
    }
}
