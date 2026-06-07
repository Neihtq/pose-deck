import Foundation
import SwiftData

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
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: inMemory
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
