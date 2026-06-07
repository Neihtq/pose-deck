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
            return try makeOnDiskContainer(configuration: configuration, storeURL: storeURL)
        }
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    /// Open the on-disk container, and if it fails to load because the persisted
    /// store is incompatible with the current schema (a schema change shipped
    /// without a migration plan), delete the store files and recreate from
    /// scratch. The mirror is a disposable cache of server state — a fresh sync
    /// rebuilds it — so trading a stale, unopenable store for an empty one is the
    /// right call for this dev app and avoids a hard launch crash on any future
    /// incompatible schema bump.
    private static func makeOnDiskContainer(
        configuration: ModelConfiguration,
        storeURL: URL
    ) throws -> ModelContainer {
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            destroyStoreFiles(at: storeURL)
            // One clean retry. If this also fails the error is not a stale-store
            // problem and should surface.
            return try ModelContainer(for: schema, configurations: [configuration])
        }
    }

    /// Remove the SQLite store and its companion / external-storage files so a
    /// fresh container can be created.
    private static func destroyStoreFiles(at storeURL: URL) {
        let fm = FileManager.default
        let dir = storeURL.deletingLastPathComponent()
        // The store, its -wal/-shm companions, and the `.externalStorage`
        // sidecars all live under the `Mirror` directory we own, so removing the
        // directory's contents reclaims everything.
        if let contents = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for url in contents { try? fm.removeItem(at: url) }
        } else {
            // Fall back to removing the known store files individually.
            let base = storeURL.lastPathComponent
            for suffix in ["", "-wal", "-shm"] {
                try? fm.removeItem(at: storeURL.deletingLastPathComponent()
                    .appendingPathComponent(base + suffix))
            }
        }
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
