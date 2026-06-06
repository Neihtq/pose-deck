// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "PoseDeckCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        // The testable logic core for the PoseDeck iOS app: Codable models,
        // REST APIClient, and the outbox sync skeleton. Pure Foundation, no
        // third-party dependencies, so it builds and tests fully offline.
        .library(
            name: "PoseDeckCore",
            targets: ["PoseDeckCore"]
        )
    ],
    dependencies: [
        // Intentionally empty: pure Foundation only so `swift build` / `swift test`
        // succeed with no network access.
    ],
    targets: [
        .target(
            name: "PoseDeckCore",
            dependencies: []
        ),
        .testTarget(
            name: "PoseDeckCoreTests",
            dependencies: ["PoseDeckCore"]
        ),
        // Integration tests that exercise the repositories against a LIVE
        // PocketBase. Every test is gated behind the POSEDECK_INTEGRATION=1 env
        // var (see IntegrationEnvironment.skipIfDisabled), so the default
        // `swift test` run stays fully offline/green when no backend is present.
        .testTarget(
            name: "PoseDeckCoreIntegrationTests",
            dependencies: ["PoseDeckCore"]
        ),
    ]
)
