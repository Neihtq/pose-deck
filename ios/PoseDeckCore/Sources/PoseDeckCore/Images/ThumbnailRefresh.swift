import Foundation

/// Pure decision helper for re-minting an expired thumbnail file token.
///
/// `card_images` file URLs carry a short-lived `?token=` (PocketBase mints it
/// fresh on every `fileURL(for:)` call). On a long-lived deck-detail screen the
/// token expires, so an already-rendered thumbnail's `AsyncImage` fails on any
/// re-fetch and is never recovered. The fix re-resolves the failing card's
/// first-image URL (fresh token) on `.failure` and swaps it in.
///
/// The subtlety — shared with the web reference and `CardImagesViewModel`'s
/// `refreshURL` — is the no-infinite-loop guard. A naive `fresh != current`
/// check (the previous implementation) does **not** stop the loop on a genuine
/// 404: because PocketBase mints a brand-new signed `?token=` on every
/// `fileURL(for:)` call, the re-minted URL is essentially *always* different
/// from the current one even when the underlying file is permanently missing.
/// So `fresh != current` stayed true forever and the chain
/// `.failure -> re-mint -> state update -> re-render -> .failure` spun
/// indefinitely, issuing a fresh `/api/files/token` POST + file GET each pass.
///
/// To be robust to per-mint token churn we (a) compare URLs by their
/// *token-stripped* identity (scheme+host+path, dropping the `token` query
/// item) so an expired-token re-mint of the same file is recognised as the same
/// image, and (b) cap how many times a given image identity may be re-minted.
/// The cap is what actually terminates a genuine-404 loop: an expired token
/// recovers on the first re-mint (the bytes then load and `.failure` stops
/// firing), whereas a permanently-broken file keeps failing — so after a small
/// number of attempts we stop re-minting and leave the broken thumbnail in
/// place rather than spinning.
public enum ThumbnailRefresh {

    /// Maximum number of token re-mints permitted for a single image identity
    /// before we stop (to break the `.failure` retry loop on a genuine 404).
    /// One re-mint is enough to recover a genuinely expired token; we allow a
    /// small margin for a transient network blip.
    public static let maxAttempts = 2

    /// Normalise a thumbnail URL to its stable identity by dropping the
    /// short-lived `token` query item (and any empty query). Two URLs for the
    /// same file differing only by a freshly minted `?token=` normalise equal.
    public static func identity(of url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        if let items = components.queryItems {
            let kept = items.filter { $0.name != "token" }
            components.queryItems = kept.isEmpty ? nil : kept
        }
        return components.url?.absoluteString ?? url.absoluteString
    }

    /// Decide whether a freshly minted thumbnail URL should replace the current
    /// one, given how many re-mints have already been attempted for the current
    /// URL's image identity.
    ///
    /// - Returns `true` only when the fresh URL is a *different image identity*
    ///   than the current one (first resolution, or the displayed image
    ///   actually changed), **or** when it is the same identity but we are still
    ///   under `maxAttempts` re-mints. Once a single identity has been re-minted
    ///   `maxAttempts` times without the `.failure` stopping (a genuine 404),
    ///   further re-mints of that same identity are refused, terminating the
    ///   loop.
    /// - Parameters:
    ///   - fresh: the newly minted URL (carries a brand-new `?token=`).
    ///   - current: the URL currently displayed (`nil` on first resolution).
    ///   - attempts: how many times *this same image identity* has already been
    ///     re-minted in the current failure streak.
    public static func shouldApply(fresh: URL, current: URL?, attempts: Int) -> Bool {
        guard let current else {
            // First resolution: always adopt.
            return true
        }
        if identity(of: fresh) != identity(of: current) {
            // The underlying image actually changed — adopt and reset the streak.
            return true
        }
        // Same image identity, only the token churned: adopt only while we are
        // still under the re-mint cap, so a genuine 404 cannot loop forever.
        return attempts < maxAttempts
    }
}
