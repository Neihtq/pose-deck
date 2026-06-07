import Foundation
import SwiftData
import PoseDeckCore

/// The SwiftData schema + `ModelContainer` factory for the on-device mirror
/// (M3 plan, STEP 10).
///
/// All five mirrored collections, the persistent outbox, and the bounded
/// consumed-keys store share one container so a single `.modelContainer(_:)` on
/// the scene wires every read/write path.
enum LocalMirrorStore {

    /// Every `@Model` type in the mirror. Keep in sync with `LocalModels.swift`.
    static let models: [any PersistentModel.Type] = [
        LocalDeck.self,
        LocalCard.self,
        LocalCardImage.self,
        LocalCardCompletion.self,
        LocalDeckGuest.self,
        LocalOutboxEntry.self,
        LocalConsumedKey.self,
    ]

    /// The shared schema.
    static var schema: Schema { Schema(models) }

    /// Build a `ModelContainer` for the mirror.
    ///
    /// - Parameter inMemory: when `true`, persistence is in-memory only (tests /
    ///   previews / a clean ephemeral session). Production passes `false` so the
    ///   mirror survives relaunch (device-verified later).
    static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let configuration: ModelConfiguration
        if inMemory {
            configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        } else {
            // Use an explicit on-disk URL so we own the directory and can pin an
            // explicit at-rest file-protection class on it (SEC-1). Applying the
            // class to the parent directory makes the SQLite store, its
            // -wal/-shm companions, and the `.externalStorage` image-blob
            // sidecars inherit `completeUntilFirstUserAuthentication` on
            // creation — see `MirrorStoreProtection` for the class rationale and
            // why it intentionally differs from the Keychain's ThisDeviceOnly.
            let storeURL = try mirrorStoreURL()
            try MirrorStoreProtection.protectDirectory(at: storeURL.deletingLastPathComponent())
            configuration = ModelConfiguration(schema: schema, url: storeURL)
        }
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    /// The on-disk location of the mirror's SQLite store: a dedicated `Mirror`
    /// subdirectory of Application Support so its protection class is set on a
    /// directory we exclusively own (not the shared container default).
    static func mirrorStoreURL() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return support
            .appendingPathComponent("PoseDeckMirror", isDirectory: true)
            .appendingPathComponent("Mirror.store", isDirectory: false)
    }
}
