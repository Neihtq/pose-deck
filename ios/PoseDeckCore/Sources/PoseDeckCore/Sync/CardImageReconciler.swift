import Foundation

/// Pure reconciliation of a card's `card_images` between the local mirror and a
/// fresh remote list (swift-5).
///
/// Background: `card_images` carry no LWW clock — create is insert-by-id, delete
/// is a hard remove-by-id (see ``SyncRecord`` / ``SyncEngine``). The realtime
/// path is therefore the *only* source that mutates a card's mirrored images
/// after the first fetch, so a non-empty mirror that short-circuits a read never
/// adopts a remotely-added image nor drops a remotely-deleted one (no resync
/// backfills `card_images`). A second device — or a missed/unobserved realtime
/// event — leaves the mirror stale: a missing-thumbnail or a 404 token URL for a
/// row the server already removed.
///
/// This computes the minimal mirror edits to converge the mirror onto the remote
/// truth, reusing the same insert-by-id / hard-delete semantics the engine uses
/// so the read-path reconcile and the realtime merge can never diverge:
///  - **inserts**: remote ids absent from the mirror (insert-by-id; an existing
///    local row already holds the freshest bytes/filename we know about, so
///    present rows are never overwritten — matches ``LocalStore/upsertCardImage``).
///  - **deletions**: mirror ids absent from the remote list (hard remove-by-id —
///    matches ``SyncEngine`` `applyCardImage` delete and the cascade evict).
///
/// The decision is pure so it is unit-testable without SwiftData or the network;
/// applying it to a ``LocalStore`` is a thin wrapper (``apply(remote:to:cardId:)``).
public enum CardImageReconciler {

    /// The minimal mirror edits to converge `mirrored` onto `remote`.
    public struct Plan: Equatable, Sendable {
        /// Remote images not yet in the mirror (insert-by-id).
        public let toInsert: [CardImage]
        /// Mirror image ids no longer present remotely (hard remove-by-id).
        public let toDelete: [String]

        public init(toInsert: [CardImage], toDelete: [String]) {
            self.toInsert = toInsert
            self.toDelete = toDelete
        }
    }

    /// Compute the reconcile plan. `remote` is the authoritative server list for
    /// the card; `mirrored` is the current local mirror for the same card.
    public static func plan(remote: [CardImage], mirrored: [CardImage]) -> Plan {
        let mirroredIds = Set(mirrored.map(\.id))
        let remoteIds = Set(remote.map(\.id))
        let toInsert = remote.filter { !mirroredIds.contains($0.id) }
        let toDelete = mirrored.map(\.id).filter { !remoteIds.contains($0) }
        return Plan(toInsert: toInsert, toDelete: toDelete)
    }

    /// Reconcile a card's mirrored images against a fresh `remote` list and
    /// return the converged set (already sorted by position), applying inserts
    /// and hard-deletes through `store`. Call this only when the fetch succeeded:
    /// an offline/failed fetch must NOT be treated as "remote is empty" (that
    /// would wrongly evict every mirrored row).
    @discardableResult
    public static func apply(
        remote: [CardImage],
        to store: any LocalStore,
        cardId: String
    ) async -> [CardImage] {
        let mirrored = await store.cardImages(cardId: cardId)
        let plan = plan(remote: remote, mirrored: mirrored)
        for image in plan.toInsert { await store.upsertCardImage(image) }
        for id in plan.toDelete { await store.hardDeleteCardImage(id: id) }
        return await store.cardImages(cardId: cardId)
    }
}
