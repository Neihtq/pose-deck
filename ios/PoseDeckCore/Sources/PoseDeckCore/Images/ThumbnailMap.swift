import Foundation

/// Pure reconciliation logic for the deck-detail thumbnail URL map.
///
/// Behind `DeckDetailViewModel`, two paths mutate the per-card thumbnail URL map
/// (`thumbnailURLs`):
///  - `loadThumbnails()` resolves *every* card's first-image URL across many
///    `await`s (one `listCardImages` + one `fileURL` mint per card, each a
///    network round-trip through the mirror), then writes the result back.
///  - `refreshThumbnail(for:)` re-mints *one* card's URL in place when its
///    `AsyncImage` reports `.failure` (an expired short-lived file `?token=`).
///
/// Both run on `@MainActor`, so there is no data race — but both *suspend* at
/// their `await`s. A `refreshThumbnail()` that lands mid-flight of a
/// `loadThumbnails()` pass would have its freshly re-minted URL silently
/// discarded the moment the load pass finished and assigned the whole map
/// wholesale (`thumbnailURLs = resolved`): a classic lost update (SWIFT-3).
///
/// The fix has two parts, both unit-testable here:
///  1. A *generation* guard so a load pass that started before a newer load pass
///     cannot overwrite the newer pass's result (``isStale``).
///  2. A *merge* (not wholesale replace) so a per-card re-mint that landed during
///     the load pass survives: load resolves the same card to its own (equally
///     fresh) token, but a concurrent re-mint may have produced a newer one, so
///     the load pass adopts its resolved entry only when that card was *not*
///     touched by a refresh after the load pass began (``merge(into:resolved:keep:)``).
///
/// This mirrors the web reference (`DeckDetailPage`), which sidesteps the problem
/// entirely by storing image *records* in its thumbnail map and delegating URL
/// minting to a per-image component — there is no shared minted-URL map to
/// clobber. iOS keeps the minted-URL map, so it reconciles explicitly here.
///
/// Side-effect-free value type so the reconciliation contract is unit-testable in
/// `PoseDeckCore`, independent of the async URL mint that lives in the app target.
/// Mirrors the role of ``ThumbnailRefresh``, ``ReorderGate`` and
/// ``ChangeTickerCoalescer`` (app-glue logic lifted into the core for tests).
public enum ThumbnailMap {

    /// Whether a `loadThumbnails()` pass that started at `passGeneration` is stale
    /// — i.e. a *newer* pass has since started (`current > passGeneration`). A
    /// stale pass must discard its result rather than overwrite the live map, so
    /// an older, slower in-flight resolve cannot clobber a newer one.
    public static func isStale(passGeneration: Int, current: Int) -> Bool {
        passGeneration < current
    }

    /// Reconcile the result of a `loadThumbnails()` pass into the live map.
    ///
    /// - Parameters:
    ///   - existing: the live `thumbnailURLs` map at the moment the pass finishes
    ///     (may contain per-card re-mints that landed *during* the pass).
    ///   - resolved: the URLs this load pass resolved, keyed by card id. The set
    ///     of keys defines the cards currently present — keys absent here are
    ///     pruned (the card was deleted / has no image).
    ///   - keep: card ids whose live entry must be preserved over this pass's
    ///     resolved entry, because a `refreshThumbnail()` re-minted them *after*
    ///     this pass began (so the live value is at least as fresh). An entry in
    ///     `keep` is only honored when `existing` actually has a URL for it.
    /// - Returns: the merged map to assign back to `thumbnailURLs`.
    public static func merge(
        existing: [String: URL],
        resolved: [String: URL],
        keep: Set<String> = []
    ) -> [String: URL] {
        var merged: [String: URL] = [:]
        for (cardId, resolvedURL) in resolved {
            if keep.contains(cardId), let live = existing[cardId] {
                // A concurrent re-mint landed during this pass: keep the live URL.
                merged[cardId] = live
            } else {
                merged[cardId] = resolvedURL
            }
        }
        return merged
    }
}
