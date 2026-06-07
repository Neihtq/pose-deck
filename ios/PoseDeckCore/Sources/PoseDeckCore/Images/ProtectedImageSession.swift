import Foundation

/// A `URLSession` for fetching protected, token-bearing `card_images` bytes
/// without ever writing them to the process-global on-disk HTTP cache
/// (SEC-IOS-B hardening).
///
/// Protected `card_images` are fetched via short-lived `?token=` URLs whose
/// responses carry a long-lived `Cache-Control`. Routed through
/// `URLSession.shared`, those decrypted private bytes land in the shared,
/// **non-per-user** `URLCache.shared` on-disk store and only get flushed at
/// sign-out (SEC-IOS-1's `MirrorPurge.clearSharedHTTPCache`). Relying on a
/// sign-out-time purge is fragile: the safer posture is to **never write the
/// bytes to a shared disk cache in the first place**.
///
/// ``ProtectedImageSession/configuration()`` builds a session configuration
/// that does exactly that — no `URLCache`, and a `reloadIgnoringLocalCacheData`
/// request policy — so token-bearing private image responses are never
/// persisted to (nor read from) the shared cache. The intended offline store
/// remains the SwiftData mirror (the pre-cache `blob`), which is purged on
/// sign-out (SEC-2).
///
/// The configuration policy lives here in PoseDeckCore so it is unit-testable
/// under `swift test`; the app wires the resulting session into its
/// `PrecacheService` download closure (compile-verified via `xcodebuild`).
public enum ProtectedImageSession {

    /// A `URLSessionConfiguration` that never persists or reads responses from
    /// any on-disk (or in-memory) HTTP cache.
    ///
    /// - `urlCache = nil` removes the backing store entirely, so a fetched
    ///   response has nowhere to be written — there is no shared cache directory
    ///   for a prior user's private bytes to remain in.
    /// - `requestCachePolicy = .reloadIgnoringLocalCacheData` ensures requests
    ///   always hit the network and never serve (or seed) a cached response,
    ///   belt-and-suspenders even if a non-nil cache were ever reintroduced.
    public static func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        // `.ephemeral` already keeps state in memory only, but be explicit and
        // defensive: drop the cache entirely and never read local cache data so
        // protected image bytes can't reach a shared on-disk store.
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return config
    }

    /// A dedicated, non-persisting `URLSession` for protected image fetches.
    ///
    /// The app passes `session.data(from:)` as the `PrecacheService` download
    /// closure (and uses the same session for any direct protected-image fetch)
    /// so no token-bearing response is ever written to `URLCache.shared`.
    public static func make() -> URLSession {
        URLSession(configuration: configuration())
    }
}
