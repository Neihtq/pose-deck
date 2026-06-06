import Foundation

/// Pure decision helper for re-minting an expired thumbnail file token.
///
/// `card_images` file URLs carry a short-lived `?token=` (PocketBase mints it
/// fresh on every `fileURL(for:)` call). On a long-lived deck-detail screen the
/// token expires, so an already-rendered thumbnail's `AsyncImage` fails on any
/// re-fetch and is never recovered. The fix re-resolves the failing card's
/// first-image URL (fresh token) on `.failure` and swaps it in.
///
/// The one subtlety — shared with the web reference and `CardImagesViewModel`'s
/// `refreshURL` — is the no-infinite-loop guard: if the re-resolved URL is
/// *unchanged* (e.g. a genuine 404, not an expiry), updating state would just
/// re-render the same broken `AsyncImage`, re-fire `.failure`, and spin. So the
/// new URL is only adopted when it actually differs from the current one.
///
/// This is a tiny, side-effect-free value type so the guard decision is
/// unit-testable in `PoseDeckCore`, independent of the (app-target) view model
/// that performs the actual async URL mint. Mirrors the web reference test
/// `DeckDetailThumbnailTokenRefresh` (react-2) and `CardImagesViewModel.refreshURL`.
public enum ThumbnailRefresh {

    /// Decide whether a freshly minted thumbnail URL should replace the current
    /// one. Returns `true` only when `fresh` differs from `current` (including
    /// the `current == nil` first-resolution case), so an unchanged re-mint does
    /// not trigger a state update that would loop the `AsyncImage` `.failure`
    /// retry forever.
    public static func shouldApply(fresh: URL, current: URL?) -> Bool {
        fresh != current
    }
}
