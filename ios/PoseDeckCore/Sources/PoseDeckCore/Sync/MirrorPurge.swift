import Foundation

/// A mirror row that holds locally-cached, never-synced binary bytes in an
/// external-storage sidecar file (the pre-cached image `blob` on
/// `LocalCardImage`).
///
/// SwiftData stores such bytes in a sidecar file on disk, and a bulk
/// `delete(model:)` does not reliably reclaim those sidecars eagerly. So before
/// tearing down the mirror on sign-out we must first null the bytes out (and
/// save) so SwiftData reclaims the sidecar, otherwise a previous user's cached
/// `card_images` bytes can survive as orphaned files in the shared, non-per-user
/// store directory (SEC-2 hygiene).
public protocol BlobBearingMirrorRow: AnyObject {
    /// Drop the locally-cached bytes (and any validator) so the external-storage
    /// sidecar is released. Must NOT touch synced fields.
    func clearCachedBlob()
}

/// Tear-down helpers for the on-device mirror (M3 plan, STEP 10 / SEC-2).
///
/// The SwiftData `@Model` rows themselves live in the app target, but the
/// *policy* — "null cached blob bytes before bulk-deleting so external-storage
/// sidecars are reclaimed" — is expressed here over the ``BlobBearingMirrorRow``
/// protocol so it can be unit-tested under `swift test` (where SwiftData's
/// on-disk behavior is not exercisable) and can never silently diverge from the
/// app's purge path.
public enum MirrorPurge {

    /// Null the cached blob bytes on every supplied image row.
    ///
    /// The app's `purgeMirror` calls this (then `save()`) **before** the bulk
    /// `delete(model:)` so the external-storage sidecar files are reclaimed
    /// rather than orphaned. Returns the number of rows cleared (so a caller /
    /// test can assert all rows were visited).
    @discardableResult
    public static func clearCachedBlobs<Row: BlobBearingMirrorRow>(
        in rows: some Sequence<Row>
    ) -> Int {
        var cleared = 0
        for row in rows {
            row.clearCachedBlob()
            cleared += 1
        }
        return cleared
    }
}
