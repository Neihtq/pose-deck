import Foundation

/// An HTTP response cache that can be flushed on sign-out.
///
/// Abstracts `Foundation.URLCache` so the sign-out purge policy can be exercised
/// under `swift test` (where the real `URLCache.shared` disk store is shared,
/// process-global, and awkward to assert on) without changing the app behavior —
/// the app passes `URLCache.shared`, which already conforms below.
public protocol PurgeableResponseCache: AnyObject {
    /// Remove every stored (memory + on-disk) cached response.
    func removeAllCachedResponses()
}

extension URLCache: PurgeableResponseCache {}

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

    /// Flush the shared HTTP response cache on sign-out (SEC-IOS-1).
    ///
    /// Pre-cached (`URLSession.shared.data(from:)`) and `AsyncImage`-displayed
    /// protected `card_images` responses carry a long-lived `Cache-Control`, so
    /// PocketBase's file bytes land in the process-global, **non-per-user**
    /// `URLCache.shared` on-disk store. The SwiftData mirror is the intended
    /// offline store and is purged on sign-out (SEC-2), so the duplicate copy in
    /// the HTTP cache is pure remanence: a previous user's decrypted private
    /// image bytes left unencrypted in a shared cache directory after they sign
    /// out. Clearing it on sign-out, alongside the mirror-blob purge, closes that
    /// data-at-rest gap so the next user of a shared install can't recover them.
    ///
    /// The app's `purgeMirror` calls this with `URLCache.shared`.
    public static func clearSharedHTTPCache(_ cache: PurgeableResponseCache) {
        cache.removeAllCachedResponses()
    }
}
