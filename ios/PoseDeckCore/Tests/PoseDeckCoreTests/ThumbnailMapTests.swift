import XCTest
@testable import PoseDeckCore

/// Regression for SWIFT-3 (the lost-update divergence from the web reference):
/// `DeckDetailViewModel.loadThumbnails()` resolves every card's thumbnail URL
/// across many `await`s and then wrote the whole map back wholesale
/// (`thumbnailURLs = resolved`), while `refreshThumbnail(for:)` re-mints a single
/// card's URL in place. Both are `@MainActor` (no data race) but both suspend, so
/// a re-mint landing mid-flight of a load pass had its fresh URL discarded by the
/// wholesale write-back.
///
/// The async URL mints live in the app-target view model (compile-verified only
/// in this env — the Simulator cannot boot). The reconciliation *decision* is
/// lifted into the pure `ThumbnailMap` helper and unit-tested here, mirroring how
/// `ThumbnailRefresh`, `ReorderGate` and `ChangeTickerCoalescer` lift app-glue
/// logic into the core.
final class ThumbnailMapTests: XCTestCase {

    private func url(_ s: String) -> URL { URL(string: s)! }

    // MARK: - Generation guard (stale-pass discard)

    /// A load pass tagged with an older generation than the current one is stale
    /// and must discard its result (a newer pass has started).
    func testIsStaleWhenNewerPassStarted() {
        XCTAssertTrue(ThumbnailMap.isStale(passGeneration: 1, current: 2))
    }

    /// The pass that is still the current generation is not stale.
    func testNotStaleWhenStillCurrent() {
        XCTAssertFalse(ThumbnailMap.isStale(passGeneration: 2, current: 2))
    }

    // MARK: - Merge / lost-update guard (the core of SWIFT-3)

    /// THE BUG: a concurrent `refreshThumbnail()` re-minted card "c1" to a fresh
    /// token *during* the load pass. The load pass resolved its own URL for "c1"
    /// (an older token captured before the re-mint). Without the merge, the
    /// wholesale write-back would replace the live fresh URL with the pass's older
    /// one. With `keep` honoring the re-minted card, the live URL survives.
    func testMergePreservesConcurrentReMint() {
        let live: [String: URL] = [
            "c1": url("https://pb/api/files/card_images/i1/p.jpg?token=remint"),
            "c2": url("https://pb/api/files/card_images/i2/p.jpg?token=old2"),
        ]
        let resolved: [String: URL] = [
            "c1": url("https://pb/api/files/card_images/i1/p.jpg?token=passOld"),
            "c2": url("https://pb/api/files/card_images/i2/p.jpg?token=pass2"),
        ]
        let merged = ThumbnailMap.merge(existing: live, resolved: resolved, keep: ["c1"])

        XCTAssertEqual(
            merged["c1"], live["c1"],
            "a card re-minted during the load pass must keep its newer live URL, not be clobbered by the pass's stale resolve"
        )
        XCTAssertEqual(
            merged["c2"], resolved["c2"],
            "a card not touched by a re-mint adopts the load pass's freshly resolved URL"
        )
    }

    /// With no concurrent re-mint (`keep` empty), the merge adopts the pass's
    /// resolved URLs wholesale — the normal refresh path.
    func testMergeAdoptsResolvedWhenNothingKept() {
        let live: [String: URL] = ["c1": url("https://pb/i1?token=stale")]
        let resolved: [String: URL] = ["c1": url("https://pb/i1?token=fresh")]
        let merged = ThumbnailMap.merge(existing: live, resolved: resolved)
        XCTAssertEqual(merged["c1"], resolved["c1"])
    }

    /// Pruning: a card present in the live map but absent from the load pass's
    /// resolved set (deleted, or its image removed) must not survive — the merged
    /// map's keys are exactly the resolved set. This is the behavior the wholesale
    /// replace gave for free and the merge must preserve.
    func testMergePrunesCardsAbsentFromResolved() {
        let live: [String: URL] = [
            "c1": url("https://pb/i1?token=a"),
            "gone": url("https://pb/gone?token=b"),
        ]
        let resolved: [String: URL] = ["c1": url("https://pb/i1?token=c")]
        let merged = ThumbnailMap.merge(existing: live, resolved: resolved)
        XCTAssertNil(merged["gone"], "a card no longer resolved must be pruned from the map")
        XCTAssertEqual(merged["c1"], resolved["c1"])
        XCTAssertEqual(merged.count, 1)
    }

    /// A `keep` for a card the load pass did not resolve is ignored — `keep` only
    /// protects entries that exist in both the live map and the resolved set, so a
    /// stale `keep` can't resurrect a pruned card.
    func testKeepIgnoredWhenCardNotResolved() {
        let live: [String: URL] = ["gone": url("https://pb/gone?token=x")]
        let resolved: [String: URL] = ["c1": url("https://pb/i1?token=y")]
        let merged = ThumbnailMap.merge(existing: live, resolved: resolved, keep: ["gone"])
        XCTAssertNil(merged["gone"])
        XCTAssertEqual(merged["c1"], resolved["c1"])
    }

    /// A `keep` for a card with no live URL falls back to the resolved URL — there
    /// is nothing fresher to preserve, so the pass's resolve is adopted.
    func testKeepFallsBackToResolvedWhenNoLiveURL() {
        let live: [String: URL] = [:]
        let resolved: [String: URL] = ["c1": url("https://pb/i1?token=fresh")]
        let merged = ThumbnailMap.merge(existing: live, resolved: resolved, keep: ["c1"])
        XCTAssertEqual(merged["c1"], resolved["c1"])
    }
}
