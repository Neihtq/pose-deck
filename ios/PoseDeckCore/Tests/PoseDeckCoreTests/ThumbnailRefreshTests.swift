import XCTest
@testable import PoseDeckCore

/// Regression for SWIFT-2 (parity with web react-2): deck-detail card
/// thumbnails carry a short-lived file `?token=`. On a long-lived detail screen
/// the token expires and the thumbnail's `AsyncImage` fails on any re-fetch,
/// with no recovery. The fix re-mints the failing card's first-image URL on
/// `.failure` and adopts it — but only when the URL actually changed, so a
/// genuine 404 (re-mint returns the same URL) does not spin the
/// `AsyncImage` `.failure` -> state-update -> re-render -> `.failure` loop.
///
/// `ThumbnailRefresh.shouldApply` is that guard, mirroring the web reference's
/// "re-mint on error" + "no infinite loop if the refreshed URL still fails" and
/// `CardImagesViewModel.refreshURL`. The async URL mint lives in the app-target
/// view model (`DeckDetailViewModel.refreshThumbnail`, compile-verified only in
/// this env since the Simulator cannot boot); the decision rule is unit-tested
/// here.
final class ThumbnailRefreshTests: XCTestCase {

    private func url(_ s: String) -> URL { URL(string: s)! }

    /// Expired-token case: the re-minted URL has a fresh `?token=`, so it
    /// differs from the stale current URL and must be adopted (the thumbnail
    /// recovers). Mirrors the web test's "re-mints the thumbnail URL" assertion.
    func testAppliesWhenTokenChanged() {
        let stale = url("https://pb.example/api/files/card_images/img1/photo.jpg?token=stale")
        let fresh = url("https://pb.example/api/files/card_images/img1/photo.jpg?token=fresh")
        XCTAssertTrue(
            ThumbnailRefresh.shouldApply(fresh: fresh, current: stale),
            "a re-minted URL with a new token must replace the expired one"
        )
    }

    /// No-loop guard: a genuine 404 re-mints to the *same* URL, so the new URL
    /// must NOT be adopted — otherwise the state update would re-render the same
    /// broken `AsyncImage`, re-fire `.failure`, and spin forever. Mirrors the
    /// web test's "does not loop forever if the refreshed URL still fails".
    func testDoesNotApplyWhenURLUnchanged() {
        let same = url("https://pb.example/api/files/card_images/img1/photo.jpg?token=same")
        XCTAssertFalse(
            ThumbnailRefresh.shouldApply(fresh: same, current: same),
            "an unchanged re-mint must not trigger a state update (no infinite reload loop)"
        )
    }

    /// First-resolution case: there is no current URL yet, so any freshly minted
    /// URL is a change and should be adopted.
    func testAppliesWhenCurrentIsNil() {
        let fresh = url("https://pb.example/api/files/card_images/img1/photo.jpg?token=fresh")
        XCTAssertTrue(
            ThumbnailRefresh.shouldApply(fresh: fresh, current: nil),
            "a first-resolution URL (no prior value) must be adopted"
        )
    }
}
