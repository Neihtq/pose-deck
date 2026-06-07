import XCTest
@testable import PoseDeckCore

/// Regression coverage for SEC-2: on sign-out the mirror purge must null out the
/// pre-cached image blob bytes BEFORE the bulk delete so SwiftData reclaims the
/// `.externalStorage` sidecar files — otherwise a previous user's cached
/// `card_images` bytes survive as orphaned files in the shared, non-per-user
/// store directory and remain readable to the next user of the same install.
///
/// The SwiftData `@Model` rows live in the app target (and on-disk sidecar
/// reclamation is not exercisable under `swift test`), so this test covers the
/// PoseDeckCore policy — ``MirrorPurge/clearCachedBlobs(in:)`` over the
/// ``BlobBearingMirrorRow`` protocol — that the app's `purgeMirror` calls before
/// its bulk delete. The app wiring is compile-verified via `xcodebuild`.
final class MirrorPurgeTests: XCTestCase {

    /// A stand-in for the app's `LocalCardImage`. Mirrors the real model's
    /// storage shape after the SwiftData decode-crash fix: `.externalStorage` on
    /// an *optional* `Data?` aborts on row materialization, so the blob is a
    /// **non-optional** `Data` (empty default) paired with an `isCached` flag.
    /// "Not yet pre-cached" is `isCached == false`; cached bytes are read via
    /// `cachedBlob`. `clearCachedBlob()` must restore the un-cached state.
    private final class FakeImageRow: BlobBearingMirrorRow {
        var blob: Data
        var isCached: Bool
        var blobETag: String?

        /// Build from an optional, mirroring `LocalCardImage.init(blob:)`.
        init(blob: Data?, blobETag: String? = nil) {
            self.blob = blob ?? Data()
            self.isCached = blob != nil
            self.blobETag = blobETag
        }

        /// Mirrors `LocalCardImage.cachedBlob`.
        var cachedBlob: Data? { isCached ? blob : nil }

        func clearCachedBlob() {
            blob = Data()
            isCached = false
            blobETag = nil
        }
    }

    func testClearCachedBlobsClearsEveryRow() {
        let rows = [
            FakeImageRow(blob: Data([0xFF, 0xD8, 0xFF]), blobETag: "etag-1"),
            FakeImageRow(blob: Data([0x01, 0x02]), blobETag: "etag-2"),
            FakeImageRow(blob: nil, blobETag: nil),
        ]

        let cleared = MirrorPurge.clearCachedBlobs(in: rows)

        XCTAssertEqual(cleared, rows.count)
        for row in rows {
            XCTAssertNil(row.cachedBlob, "cached image bytes must be released so the sidecar is reclaimed")
            XCTAssertFalse(row.isCached, "a cleared row must report itself un-cached")
            XCTAssertTrue(row.blob.isEmpty, "the underlying bytes must be emptied, not just flagged")
            XCTAssertNil(row.blobETag, "the cached validator must be cleared alongside the bytes")
        }
    }

    func testClearCachedBlobsOnEmptySequenceIsNoOp() {
        let cleared = MirrorPurge.clearCachedBlobs(in: [FakeImageRow]())
        XCTAssertEqual(cleared, 0)
    }

    /// Belt-and-suspenders: after clearing, no row retains any image bytes — the
    /// invariant the sign-out purge depends on.
    func testNoBytesRemainAfterClear() {
        let rows = (0..<5).map { i in FakeImageRow(blob: Data([UInt8(i)]), blobETag: "e\(i)") }
        MirrorPurge.clearCachedBlobs(in: rows)
        let remainingBytes = rows.map(\.blob.count).reduce(0, +)
        XCTAssertEqual(remainingBytes, 0, "no image bytes may remain after the sign-out purge")
        XCTAssertTrue(rows.allSatisfy { $0.cachedBlob == nil }, "no row may report cached bytes")
    }

    /// The blob-presence semantics the fix preserves: an absent blob (nil at
    /// init) means "not yet pre-cached" (`isCached == false`, `cachedBlob == nil`)
    /// while a present blob — even empty bytes — reads back through `cachedBlob`.
    /// This is what distinguishes a not-yet-cached image from a cached one in the
    /// offline read path, without an optional `Data?` that would crash SwiftData.
    // MARK: - SEC-IOS-1: shared HTTP cache flush on sign-out

    /// A stand-in for `URLCache.shared`, recording flush calls so we can assert
    /// the sign-out purge policy reaches the HTTP cache. The real
    /// `URLCache: PurgeableResponseCache` conformance is compile-verified.
    private final class SpyResponseCache: PurgeableResponseCache {
        private(set) var flushCount = 0
        func removeAllCachedResponses() { flushCount += 1 }
    }

    /// SEC-IOS-1: the sign-out purge must flush the shared HTTP response cache so
    /// a prior user's pre-cached / AsyncImage-loaded protected `card_images`
    /// bytes don't survive as unencrypted remanence in the process-global,
    /// non-per-user `URLCache.shared` on-disk store. `URLCache.shared` itself is
    /// process-global and shared across `swift test` cases, so we cover the
    /// policy over the `PurgeableResponseCache` seam the app's `purgeMirror`
    /// invokes; the `URLCache.shared` wiring is compile-verified via `xcodebuild`.
    func testClearSharedHTTPCacheFlushesTheCache() {
        let cache = SpyResponseCache()
        MirrorPurge.clearSharedHTTPCache(cache)
        XCTAssertEqual(cache.flushCount, 1, "sign-out must flush the shared HTTP response cache so protected image bytes don't persist for the next user")
    }

    func testCachedBlobReflectsPresenceNotEmptiness() {
        let notCached = FakeImageRow(blob: nil)
        XCTAssertFalse(notCached.isCached)
        XCTAssertNil(notCached.cachedBlob, "an un-cached image must read back as nil bytes")

        let cachedEmpty = FakeImageRow(blob: Data())
        XCTAssertTrue(cachedEmpty.isCached, "a present (even empty) blob counts as cached")
        XCTAssertEqual(cachedEmpty.cachedBlob, Data(), "cached empty bytes read back as empty, not nil")

        let cachedBytes = FakeImageRow(blob: Data([0xAB, 0xCD]))
        XCTAssertTrue(cachedBytes.isCached)
        XCTAssertEqual(cachedBytes.cachedBlob, Data([0xAB, 0xCD]))
    }
}
