import SwiftUI
import PoseDeckCore

/// A drop-in replacement for `AsyncImage` for protected, token-bearing
/// `card_images` URLs that fetches through a dedicated non-persisting session
/// (SEC-IOS-B).
///
/// `AsyncImage(url:)` always loads through `URLSession.shared`, whose
/// process-global `URLCache.shared` writes the fetched (decrypted, private)
/// image bytes to a shared, **non-per-user** on-disk cache directory — only
/// flushed at sign-out. This view instead loads the bytes via
/// ``PoseDeckCore/ProtectedImageSession`` (ephemeral, no `URLCache`,
/// `reloadIgnoringLocalCacheData`), so a protected image response is **never**
/// written to that shared disk cache, removing the cross-user remanence risk
/// without relying on a sign-out-time purge. The intended offline store remains
/// the SwiftData mirror blob (purged on sign-out, SEC-2).
///
/// It mirrors `AsyncImage`'s phase-based content builder so call sites swap
/// `AsyncImage` → `ProtectedAsyncImage` with no other change: callers keep
/// their existing `.success` / `.failure` (token-refresh) / `.empty` handling,
/// including the expired-token `.failure` → re-mint loop guard
/// (``PoseDeckCore/ThumbnailRefresh``).
///
/// App-only SwiftUI (not unit-testable in this env, which can't boot a
/// Simulator); the load-policy seam it depends on — `ProtectedImageSession` —
/// is unit-tested in PoseDeckCore. This view is compile-verified via
/// `xcodebuild`.
/// Holds one process-wide non-persisting session for all protected image loads,
/// so each ``ProtectedAsyncImage`` doesn't spin up its own session. (A static
/// stored property can't live on the generic ``ProtectedAsyncImage`` itself.)
enum ProtectedImageSessionHolder {
    static let shared = ProtectedImageSession.make()
}

struct ProtectedAsyncImage<Content: View>: View {
    private let url: URL?
    private let content: (AsyncImagePhase) -> Content

    @State private var phase: AsyncImagePhase = .empty

    /// `session` defaults to the shared protected (non-persisting) session and
    /// is injectable for previews/tests.
    private let session: URLSession

    init(
        url: URL?,
        session: URLSession = ProtectedImageSessionHolder.shared,
        @ViewBuilder content: @escaping (AsyncImagePhase) -> Content
    ) {
        self.url = url
        self.session = session
        self.content = content
    }

    var body: some View {
        content(phase)
            // Reload whenever the URL changes (e.g. a re-minted fresh token),
            // mirroring `AsyncImage`'s url-identity reload.
            .task(id: url) { await load() }
    }

    private func load() async {
        guard let url else {
            phase = .empty
            return
        }
        phase = .empty
        do {
            let (data, _) = try await session.data(from: url)
            guard let uiImage = UIImage(data: data) else {
                phase = .failure(URLError(.cannotDecodeContentData))
                return
            }
            // Ignore a result that arrived after the URL changed under us.
            guard !Task.isCancelled else { return }
            phase = .success(Image(uiImage: uiImage))
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failure(error)
        }
    }
}

// Compile-only preview so this new view file is exercised by the build (catches
// dead-code drift). The Simulator can't boot in this env, so this is never
// rendered here — it stands in for the runnable smoke. The nil URL resolves to
// `.empty` without any network, so the preview is hermetic.
#Preview("ProtectedAsyncImage — empty/loading") {
    ProtectedAsyncImage(url: nil) { phase in
        switch phase {
        case .empty: ProgressView()
        case .success(let image): image.resizable().scaledToFit()
        case .failure: Image(systemName: "photo")
        @unknown default: EmptyView()
        }
    }
}
