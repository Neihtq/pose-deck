import Foundation

/// Pure decision helpers for the deck soft-delete / restore cascade over the
/// **local mirror** (M3 plan, STEP 9–10 / ARCHITECTURE.md §4.3).
///
/// The iOS mirror hides a deck's children by stamping each *live* child's
/// `deletedAt` to the deck's own `deletedAt` at soft-delete time (so the
/// `listCards` filter — which is purely `deletedAt == nil`, with no
/// parent-deck-trashed join — excludes them). The inverse restore must therefore
/// un-hide **only** the children the cascade hid, identified by their `deletedAt`
/// matching the deck's prior `deletedAt`. A child the user *individually* trashed
/// before the deck was trashed carries a *different* `deletedAt` and MUST stay
/// trashed across a deck restore.
///
/// This rule is shared by the realtime path (``SyncEngine/cascadeDeckRestore``)
/// and the app's optimistic `MirrorDeckRepository.restoreDeck`, lifted here so
/// the two can never diverge and the predicate is unit-testable under
/// `swift test` without SwiftData (folds the gauntlet finding: the optimistic
/// path used to un-hide *every* trashed child, resurrecting individually-trashed
/// cards on deck restore).
public enum DeckCascade {

    /// The ids of `cards` that a deck restore should un-hide.
    ///
    /// A card qualifies iff its `deletedAt` equals the deck's prior `deletedAt`
    /// (`hiddenAt`) — i.e. it was hidden by the deck cascade, not individually
    /// trashed. When `hiddenAt` is `nil` (the deck was not actually soft-deleted)
    /// nothing is un-hidden.
    ///
    /// - Parameters:
    ///   - cards: the deck's children (any subset; live cards are simply ignored).
    ///   - hiddenAt: the deck's `deletedAt` immediately before the restore.
    /// - Returns: ids of children to un-hide, preserving input order.
    public static func childIdsToUnhideOnRestore(
        cards: [Card],
        hiddenAt: Date?
    ) -> [String] {
        guard let hiddenAt else { return [] }
        return cards.compactMap { card in
            card.deletedAt == hiddenAt ? card.id : nil
        }
    }
}
