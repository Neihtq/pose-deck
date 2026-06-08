import XCTest
@testable import PoseDeckCore

/// Regression for SWIFT-2 (parity with web react-2) and SWIFT-A1: deck-detail
/// card thumbnails carry a short-lived file `?token=`. On a long-lived detail
/// screen the token expires and the thumbnail's `AsyncImage` fails on any
/// re-fetch, with no recovery. The fix re-mints the failing card's first-image
/// URL on `.failure` and adopts it.
///
/// SWIFT-A1: the no-loop guard must survive per-mint token churn. PocketBase
/// mints a brand-new signed `?token=` on every `fileURL(for:)` call, so a naive
/// `fresh != current` guard is *always* true on a genuine 404 (the path is the
/// same but the token differs each time) and the `.failure -> re-mint ->
/// re-render -> .failure` chain spins forever. `ThumbnailRefresh.shouldApply`
/// now compares token-stripped identity and caps re-mints per identity so a
/// genuine 404 terminates after `maxAttempts`.
///
/// The async URL mint + attempt-count bookkeeping lives in the app-target view
/// models (`DeckDetailViewModel.refreshThumbnail` / `CardImagesViewModel`,
/// compile-verified only in this env since the Simulator cannot boot); the
/// decision rule is unit-tested here.
final class ThumbnailRefreshTests: XCTestCase {

    private func url(_ s: String) -> URL { URL(string: s)! }

    /// Expired-token case: the re-minted URL has a fresh `?token=`, so it differs
    /// from the stale current URL and must be adopted (the thumbnail recovers).
    /// Same path, only the token churned — adopted because we are under the cap.
    func testAppliesWhenTokenChangedAndUnderCap() {
        let stale = url("https://pb.example/api/files/card_images/img1/photo.jpg?token=stale")
        let fresh = url("https://pb.example/api/files/card_images/img1/photo.jpg?token=fresh")
        XCTAssertTrue(
            ThumbnailRefresh.shouldApply(fresh: fresh, current: stale, attempts: 0),
            "a re-minted URL with a new token must replace the expired one"
        )
    }

    /// First-resolution case: there is no current URL yet, so any freshly minted
    /// URL is a change and should be adopted (regardless of attempts).
    func testAppliesWhenCurrentIsNil() {
        let fresh = url("https://pb.example/api/files/card_images/img1/photo.jpg?token=fresh")
        XCTAssertTrue(
            ThumbnailRefresh.shouldApply(fresh: fresh, current: nil, attempts: 0),
            "a first-resolution URL (no prior value) must be adopted"
        )
    }

    /// SWIFT-A1 core regression: a genuine 404 re-mints to a *different-token but
    /// same-path* URL on every pass. The old `fresh != current` guard would adopt
    /// it forever, spinning the `.failure` loop. The cap must refuse re-mints of
    /// the same identity once `attempts` reaches `maxAttempts`, terminating the
    /// loop even though `fresh != current`.
    func testDoesNotApplyOnTokenChurnOnceCapReached() {
        let mintA = url("https://pb.example/api/files/card_images/img1/photo.jpg?token=A")
        let mintB = url("https://pb.example/api/files/card_images/img1/photo.jpg?token=B")
        // The URLs differ (token churn) — proves the old `fresh != current` guard
        // would still fire here.
        XCTAssertNotEqual(mintA, mintB)
        XCTAssertFalse(
            ThumbnailRefresh.shouldApply(
                fresh: mintB,
                current: mintA,
                attempts: ThumbnailRefresh.maxAttempts
            ),
            "same-image token churn must stop being adopted once the re-mint cap is reached"
        )
    }

    /// Walk the genuine-404 loop the way the view model drives it: each `.failure`
    /// re-mints with a fresh token and increments the attempt counter. The chain
    /// must adopt only a bounded number of times, then refuse — proving the loop
    /// terminates instead of issuing unbounded token POSTs.
    func testTokenChurnLoopTerminates() {
        var attempts = 0
        var current = url("https://pb.example/api/files/card_images/img1/photo.jpg?token=t0")
        var adoptions = 0
        // Simulate many `.failure` passes; each mints a unique token.
        for i in 1...10 {
            let fresh = url("https://pb.example/api/files/card_images/img1/photo.jpg?token=t\(i)")
            if ThumbnailRefresh.shouldApply(fresh: fresh, current: current, attempts: attempts) {
                current = fresh
                attempts += 1
                adoptions += 1
            }
        }
        XCTAssertEqual(
            adoptions,
            ThumbnailRefresh.maxAttempts,
            "a genuine-404 token-churn loop must adopt at most maxAttempts times, then stop"
        )
    }

    /// Identity change (a genuinely different image, not just a new token) resets
    /// the streak: it must be adopted even if the prior identity had exhausted its
    /// cap, so swapping the displayed image still recovers.
    func testAppliesWhenImageIdentityChangesDespiteCap() {
        let oldImg = url("https://pb.example/api/files/card_images/img1/photo.jpg?token=A")
        let newImg = url("https://pb.example/api/files/card_images/img2/other.jpg?token=B")
        XCTAssertTrue(
            ThumbnailRefresh.shouldApply(
                fresh: newImg,
                current: oldImg,
                attempts: ThumbnailRefresh.maxAttempts
            ),
            "a different image identity must be adopted even past the re-mint cap"
        )
    }

    /// `identity(of:)` must strip the volatile `token` query item while keeping
    /// scheme/host/path (and any other query item) so same-file re-mints
    /// normalise equal but genuinely different files do not.
    func testIdentityStripsTokenButKeepsPathAndOtherQuery() {
        let a = url("https://pb.example/api/files/card_images/img1/photo.jpg?token=AAA")
        let b = url("https://pb.example/api/files/card_images/img1/photo.jpg?token=BBB")
        XCTAssertEqual(ThumbnailRefresh.identity(of: a), ThumbnailRefresh.identity(of: b))

        let withThumb = url("https://pb.example/api/files/card_images/img1/photo.jpg?token=X&thumb=100x100")
        XCTAssertNotEqual(
            ThumbnailRefresh.identity(of: a),
            ThumbnailRefresh.identity(of: withThumb),
            "a non-token query item (e.g. thumb size) is part of identity"
        )

        let other = url("https://pb.example/api/files/card_images/img2/photo.jpg?token=AAA")
        XCTAssertNotEqual(
            ThumbnailRefresh.identity(of: a),
            ThumbnailRefresh.identity(of: other),
            "a different record id is a different identity"
        )
    }
}
