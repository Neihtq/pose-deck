import Foundation

/// Pure helpers for the PocketBase protected-file URL shape
/// (`/api/files/<collection>/<recordId>/<filename>?token=...`).
///
/// The image render path needs to map a token-bearing file URL back to its
/// `card_images` **record id** so it can look up (and write back) the locally
/// cached blob for that image — keyed by record id, not by the full URL (the
/// `?token=` query rotates on every mint, so the URL is not a stable cache key).
///
/// Kept pure + here in the core so the parse is exhaustively unit-testable
/// without booting a Simulator; the app's `ProtectedAsyncImage` calls it.
public enum CardImageFileURL {

    /// The PocketBase files path marker. The component immediately **two** past
    /// it is the record id (collection sits at +1, record id at +2, filename at
    /// +3): `/api/files/<collection>/<recordId>/<filename>`.
    private static let filesMarker = "files"

    /// Extract the record id from a PocketBase file URL, or `nil` if the URL is
    /// not a `/api/files/<collection>/<recordId>/<filename>` path.
    ///
    /// Robust to the leading empty path component (URLs begin with `/`), an
    /// absent or extra query string, and a missing filename (returns `nil` —
    /// without a filename there is no concrete file, so no blob to key).
    public static func recordId(from url: URL) -> String? {
        // `pathComponents` already percent-decodes and drops the query/fragment.
        let parts = url.pathComponents.filter { $0 != "/" }
        guard let markerIdx = parts.firstIndex(of: filesMarker) else { return nil }
        let recordIdx = markerIdx + 2   // skip the collection segment at +1
        let filenameIdx = markerIdx + 3 // require a filename to follow
        guard filenameIdx < parts.count else { return nil }
        let recordId = parts[recordIdx]
        return recordId.isEmpty ? nil : recordId
    }
}
