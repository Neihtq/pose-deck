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

    /// A stand-in for the app's `LocalCardImage`: holds cached bytes and a
    /// validator that ``BlobBearingMirrorRow/clearCachedBlob()`` must release.
    private final class FakeImageRow: BlobBearingMirrorRow {
        var blob: Data?
        var blobETag: String?
        init(blob: Data?, blobETag: String? = nil) {
            self.blob = blob
            self.blobETag = blobETag
        }
        func clearCachedBlob() {
            blob = nil
            blobETag = nil
        }
    }

    func testClearCachedBlobsNullsEveryRow() {
        let rows = [
            FakeImageRow(blob: Data([0xFF, 0xD8, 0xFF]), blobETag: "etag-1"),
            FakeImageRow(blob: Data([0x01, 0x02]), blobETag: "etag-2"),
            FakeImageRow(blob: nil, blobETag: nil),
        ]

        let cleared = MirrorPurge.clearCachedBlobs(in: rows)

        XCTAssertEqual(cleared, rows.count)
        for row in rows {
            XCTAssertNil(row.blob, "cached image bytes must be released so the sidecar is reclaimed")
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
        let remainingBytes = rows.compactMap(\.blob).reduce(0) { $0 + $1.count }
        XCTAssertEqual(remainingBytes, 0, "no image bytes may remain after the sign-out purge")
    }
}
