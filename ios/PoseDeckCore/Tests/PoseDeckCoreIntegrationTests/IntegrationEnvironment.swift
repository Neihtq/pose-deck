import Foundation
import XCTest
@testable import PoseDeckCore

/// Shared configuration + gating for the live-backend integration suite.
///
/// These tests hit a REAL PocketBase instance, so they are OFF by default: the
/// gate (`POSEDECK_INTEGRATION=1`) keeps the standard offline `swift test` run
/// green when no backend is present. When enabled, the suite reads the backend
/// URL and the seed owner/guest credentials from env vars, falling back to the
/// local dev-stack defaults documented in `backend/README.md`.
enum IntegrationEnvironment {

    /// Whether the integration suite should run. Driven by `POSEDECK_INTEGRATION`
    /// being set to a truthy value (`1`, `true`, `yes`, case-insensitive).
    static var isEnabled: Bool {
        guard let raw = env("POSEDECK_INTEGRATION")?.lowercased() else { return false }
        return ["1", "true", "yes", "on"].contains(raw)
    }

    /// Base URL of the live PocketBase, from `POSEDECK_BASE_URL` or the dev default.
    static var baseURL: URL {
        let raw = env("POSEDECK_BASE_URL") ?? "http://localhost:8090"
        guard let url = URL(string: raw) else {
            fatalError("POSEDECK_BASE_URL is not a valid URL: \(raw)")
        }
        return url
    }

    /// Seed owner credentials (dev-stack defaults from backend/README.md).
    static var ownerEmail: String { env("POSEDECK_OWNER_EMAIL") ?? "owner@posedeck.test" }
    static var ownerPassword: String { env("POSEDECK_OWNER_PASSWORD") ?? "changeme123" }

    /// Seed guest credentials.
    static var guestEmail: String { env("POSEDECK_GUEST_EMAIL") ?? "guest@posedeck.test" }
    static var guestPassword: String { env("POSEDECK_GUEST_PASSWORD") ?? "changeme123" }

    /// Skip the calling test (XCTSkip) when the integration gate is off, so the
    /// default offline `swift test` run reports green without any backend.
    ///
    /// - Returns: `false` when the suite is disabled (caller should `return`),
    ///   `true` when it should proceed. Throws `XCTSkip` so XCTest records the
    ///   test as skipped rather than passed/failed.
    static func skipIfDisabled() throws {
        try XCTSkipUnless(
            isEnabled,
            "Live-backend integration tests are gated. Set POSEDECK_INTEGRATION=1 (and run a PocketBase dev stack) to enable."
        )
    }

    /// Build a fresh APIClient pointed at the live backend, using a NON-shared
    /// ephemeral session so cookies/caches don't leak between tests.
    static func makeClient() -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        return APIClient(baseURL: baseURL, session: URLSession(configuration: config))
    }

    private static func env(_ key: String) -> String? {
        guard let value = ProcessInfo.processInfo.environment[key], !value.isEmpty else {
            return nil
        }
        return value
    }
}
