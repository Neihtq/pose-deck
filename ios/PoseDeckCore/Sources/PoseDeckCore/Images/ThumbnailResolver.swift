import Foundation

/// Concurrent, cancellation-aware fan-out for a `loadThumbnails()` pass.
///
/// `DeckDetailViewModel.loadThumbnails()` used to resolve each card's first-image
/// thumbnail URL in a plain `for card in cards { await … }` loop: that issues the
/// per-card work (a `listCardImages` mirror reconcile + a `fileURL` token mint,
/// each a network round-trip) **serially**, so a deck-detail screen with N cards
/// paid N round-trips back-to-back per refresh, and a refresh fires on every
/// `MirrorChangeTicker` bump and editor return (`swift-mirror-image-network-per-read`).
/// The loop also never observed `Task.isCancelled`, so a pass superseded by a
/// newer trigger ran to completion doing wasted network work before its result
/// was discarded at write-back.
///
/// This helper fixes both at the root, matching the web reference
/// (`DeckDetailPage`, which fans the per-card reads out with `Promise.all`):
///  - It runs the per-card resolver **concurrently** in a `TaskGroup`, so a
///    refresh is one fan-out of round-trips instead of N serialized ones.
///  - It checks `Task.isCancelled` before scheduling and on each collected
///    result, so a pass that SwiftUI's `.task(id:)` cancelled (a newer ticker
///    revision) bails early instead of running every remaining round-trip.
///
/// Side-effect-free over an injected async closure so the fan-out / cancellation
/// contract is exhaustively unit-testable in `PoseDeckCore` — the real network
/// resolve lives in the app target (compile-verified only; the Simulator cannot
/// boot in this env). Mirrors the role of ``ThumbnailMap``, ``ThumbnailRefresh``,
/// ``ReorderGate`` and ``ShootTaskScheduler`` (app-glue logic lifted into the
/// core for tests).
public enum ThumbnailResolver {

    /// Resolve a thumbnail URL for each id concurrently.
    ///
    /// - Parameters:
    ///   - ids: the card ids to resolve, in any order (the result is a map, so
    ///     ordering does not matter).
    ///   - resolve: async per-card work returning the card's thumbnail URL, or
    ///     `nil` when the card has no image / failed to resolve (best-effort: a
    ///     per-card failure drops that entry, it does not fail the whole pass).
    /// - Returns: a map of card id → resolved URL for every id that produced a
    ///   non-`nil` URL. Returns whatever was collected so far (possibly empty) if
    ///   the surrounding task is cancelled.
    public static func resolveAll(
        ids: [String],
        resolve: @Sendable @escaping (String) async -> URL?
    ) async -> [String: URL] {
        guard !Task.isCancelled, !ids.isEmpty else { return [:] }
        return await withTaskGroup(of: (String, URL?).self) { group in
            for id in ids {
                group.addTask {
                    // Skip launching work the caller already abandoned.
                    if Task.isCancelled { return (id, nil) }
                    return (id, await resolve(id))
                }
            }
            var resolved: [String: URL] = [:]
            for await (id, url) in group {
                // A newer pass (or screen teardown) cancelled us mid-collect:
                // stop draining and let the caller discard the partial result.
                if Task.isCancelled {
                    group.cancelAll()
                    break
                }
                if let url { resolved[id] = url }
            }
            return resolved
        }
    }
}
