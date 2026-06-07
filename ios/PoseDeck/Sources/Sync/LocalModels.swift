import Foundation
import SwiftData
import PoseDeckCore

/// SwiftData `@Model` classes mirroring the five synced PocketBase collections
/// plus the persistent outbox (M3 plan, STEP 10 / ARCHITECTURE.md §4.1).
///
/// Design notes that match the locked model and the cross-cutting invariants:
///  - Each row's `id` is `@Attribute(.unique)` so `upsert`-by-id is a single
///    fetch-or-insert (no duplicate rows on a realtime echo of a create).
///  - Only `decks`/`cards` carry `clientUpdatedAt`; `card_completions` carries
///    `changedAt`; **images and guests have no LWW clock** (invariant #3) — so
///    `LocalCardImage` deliberately has NO `clientUpdatedAt`.
///  - **Local-only fields are never synced**: `pinnedForOffline`, `precachedAt`,
///    and the image `blob` / `blobETag` live only on-device. The mirror→server
///    write path (the outbox payloads built in PoseDeckCore) never reads them.
///  - The image `blob` uses `.externalStorage` so large JPEG bytes are stored as
///    a sidecar file rather than bloating the SQLite store. It is a **non-optional**
///    `Data` (defaulting to empty) paired with an `isCached` flag: `.externalStorage`
///    on an *optional* `Data?` makes SwiftData emit a `decodeIfPresent` that fails a
///    dynamic cast and aborts on the NSManagedObjectContext queue when a row is
///    materialized. `isCached` preserves the "not-yet-precached" semantics (no bytes)
///    without the optional payload.
///
/// Each model conforms to ``MirrorRow`` so the shared ``MirrorMerge`` LWW rule
/// applies uniformly (images/guests report a `nil` clock → always-apply insert).

@Model
final class LocalDeck: MirrorRow {
    @Attribute(.unique) var id: String
    var owner: String
    var name: String
    var shootDate: Date?
    var clientUpdatedAt: Date?
    var created: Date?
    var updated: Date?
    var deletedAt: Date?

    /// Local-only: the user pinned this deck for offline use. Never synced.
    var pinnedForOffline: Bool
    /// Local-only: when the pre-cache last fully succeeded for this deck. Never synced.
    var precachedAt: Date?

    var mirrorOrderingTimestamp: Date? { clientUpdatedAt }

    init(
        id: String,
        owner: String,
        name: String,
        shootDate: Date? = nil,
        clientUpdatedAt: Date? = nil,
        created: Date? = nil,
        updated: Date? = nil,
        deletedAt: Date? = nil,
        pinnedForOffline: Bool = false,
        precachedAt: Date? = nil
    ) {
        self.id = id
        self.owner = owner
        self.name = name
        self.shootDate = shootDate
        self.clientUpdatedAt = clientUpdatedAt
        self.created = created
        self.updated = updated
        self.deletedAt = deletedAt
        self.pinnedForOffline = pinnedForOffline
        self.precachedAt = precachedAt
    }
}

@Model
final class LocalCard: MirrorRow {
    @Attribute(.unique) var id: String
    var deck: String
    var position: Int
    var title: String
    var timeSlot: String?
    var subjects: String?
    var direction: String?
    var notes: String?
    var clientUpdatedAt: Date?
    var created: Date?
    var updated: Date?
    var deletedAt: Date?

    var mirrorOrderingTimestamp: Date? { clientUpdatedAt }

    init(
        id: String,
        deck: String,
        position: Int,
        title: String,
        timeSlot: String? = nil,
        subjects: String? = nil,
        direction: String? = nil,
        notes: String? = nil,
        clientUpdatedAt: Date? = nil,
        created: Date? = nil,
        updated: Date? = nil,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.deck = deck
        self.position = position
        self.title = title
        self.timeSlot = timeSlot
        self.subjects = subjects
        self.direction = direction
        self.notes = notes
        self.clientUpdatedAt = clientUpdatedAt
        self.created = created
        self.updated = updated
        self.deletedAt = deletedAt
    }
}

@Model
final class LocalCardImage: MirrorRow, BlobBearingMirrorRow {
    @Attribute(.unique) var id: String
    var card: String
    var position: Int
    var file: String?
    var created: Date?

    /// Local-only pre-cached JPEG bytes; stored as a sidecar file (never synced).
    ///
    /// Non-optional `Data` defaulting to empty: `.externalStorage` on an *optional*
    /// `Data?` makes SwiftData generate a `decodeIfPresent` that fails a dynamic
    /// cast and aborts when a row is materialized on the NSManagedObjectContext
    /// queue. "Not yet pre-cached" is expressed by `isCached == false` (and an
    /// empty `blob`), never by a nil payload. Read cached bytes via `cachedBlob`.
    @Attribute(.externalStorage) var blob: Data
    /// Whether `blob` holds genuine pre-cached bytes (vs. the empty default).
    /// Local-only; preserves the prior `blob != nil` semantics.
    var isCached: Bool
    /// Local-only ETag/validator for the cached `blob`, so a stale blob can be
    /// invalidated on a re-cache. Never synced. (No `clientUpdatedAt` — images
    /// have no LWW clock per invariant #3.)
    var blobETag: String?

    /// Images have no LWW clock → always-apply insert / hard-delete.
    var mirrorOrderingTimestamp: Date? { nil }

    /// The cached bytes if present, else `nil` — preserves the old `blob: Data?`
    /// read semantics for callers (the offline view layer) that treat "no cached
    /// bytes" as a distinct state from "empty bytes".
    var cachedBlob: Data? { isCached ? blob : nil }

    init(
        id: String,
        card: String,
        position: Int,
        file: String? = nil,
        created: Date? = nil,
        blob: Data? = nil,
        blobETag: String? = nil
    ) {
        self.id = id
        self.card = card
        self.position = position
        self.file = file
        self.created = created
        self.blob = blob ?? Data()
        self.isCached = blob != nil
        self.blobETag = blobETag
    }
}

@Model
final class LocalCardCompletion: MirrorRow {
    @Attribute(.unique) var id: String
    var card: String
    var user: String
    /// Raw `CardCompletion.State` rawValue (`done`/`skipped`/`pending`).
    var stateRaw: String
    var changedAt: Date?

    var mirrorOrderingTimestamp: Date? { changedAt }

    init(
        id: String,
        card: String,
        user: String,
        stateRaw: String,
        changedAt: Date? = nil
    ) {
        self.id = id
        self.card = card
        self.user = user
        self.stateRaw = stateRaw
        self.changedAt = changedAt
    }
}

@Model
final class LocalDeckGuest: MirrorRow {
    @Attribute(.unique) var id: String
    var deck: String
    var user: String
    var grantedAt: Date?

    /// Guests have no LWW clock → insert on grant, hard remove on revoke.
    var mirrorOrderingTimestamp: Date? { nil }

    init(id: String, deck: String, user: String, grantedAt: Date? = nil) {
        self.id = id
        self.deck = deck
        self.user = user
        self.grantedAt = grantedAt
    }
}

/// The persistent outbox row backing ``SwiftDataOutbox`` (the PoseDeckCore
/// ``OutboxQueue`` protocol). Mirrors ``OutboxEntry``'s fields.
@Model
final class LocalOutboxEntry {
    @Attribute(.unique) var id: UUID
    /// Raw `OutboxMutationType` rawValue (`create`/`update`/`delete`).
    var typeRaw: String
    /// The target collection name (`decks`/`cards`/`card_images`/…).
    ///
    /// NOTE: this property must NOT be named `entity`. `NSManagedObject` (which a
    /// SwiftData `@Model` is bridged onto) already exposes an `entity` accessor
    /// returning an `NSEntityDescription`; a stored `@Model` attribute named
    /// `entity` shadows it, so when SwiftData materializes a row it reads the
    /// `NSEntityDescription` for the `entity` key and aborts trying to
    /// dynamic-cast it to `String` ("Could not cast value of type
    /// 'NSEntityDescription' to 'NSString'") on the NSManagedObjectContext queue.
    var entityName: String
    var payload: Data
    var idempotencyKey: UUID
    var localTimestamp: Date
    var retryCount: Int
    var lastError: String?

    init(
        id: UUID,
        typeRaw: String,
        entityName: String,
        payload: Data,
        idempotencyKey: UUID,
        localTimestamp: Date,
        retryCount: Int = 0,
        lastError: String? = nil
    ) {
        self.id = id
        self.typeRaw = typeRaw
        self.entityName = entityName
        self.payload = payload
        self.idempotencyKey = idempotencyKey
        self.localTimestamp = localTimestamp
        self.retryCount = retryCount
        self.lastError = lastError
    }
}

/// A bounded record of recently-consumed idempotency keys, so a confirmed
/// mutation cannot be re-enqueued under the same key after its outbox row is
/// removed — without keeping an unbounded in-memory `Set` for the life of the
/// process (M3 plan, STEP 10: bounded/aged consumed-keys store).
@Model
final class LocalConsumedKey {
    @Attribute(.unique) var key: UUID
    var consumedAt: Date

    init(key: UUID, consumedAt: Date) {
        self.key = key
        self.consumedAt = consumedAt
    }
}

// MARK: - Mirror ⇄ domain bridging

extension LocalDeck {
    /// Project to the PoseDeckCore domain ``Deck`` (drops local-only fields).
    var asDeck: Deck {
        Deck(
            id: id, owner: owner, name: name, shootDate: shootDate,
            clientUpdatedAt: clientUpdatedAt, created: created, updated: updated,
            deletedAt: deletedAt
        )
    }

    /// Copy syncable fields from a domain ``Deck`` (preserves local-only fields).
    func apply(_ deck: Deck) {
        owner = deck.owner
        name = deck.name
        shootDate = deck.shootDate
        clientUpdatedAt = deck.clientUpdatedAt
        created = deck.created
        updated = deck.updated
        deletedAt = deck.deletedAt
    }
}

extension LocalCard {
    var asCard: Card {
        Card(
            id: id, deck: deck, position: position, title: title,
            timeSlot: timeSlot, subjects: subjects, direction: direction,
            notes: notes, clientUpdatedAt: clientUpdatedAt, created: created,
            updated: updated, deletedAt: deletedAt
        )
    }

    func apply(_ card: Card) {
        deck = card.deck
        position = card.position
        title = card.title
        timeSlot = card.timeSlot
        subjects = card.subjects
        direction = card.direction
        notes = card.notes
        clientUpdatedAt = card.clientUpdatedAt
        created = card.created
        updated = card.updated
        deletedAt = card.deletedAt
    }
}

extension LocalCardImage {
    var asCardImage: CardImage {
        CardImage(id: id, card: card, position: position, file: file, created: created)
    }

    /// Apply syncable fields from a domain ``CardImage`` (preserves `blob`/`blobETag`).
    func apply(_ image: CardImage) {
        card = image.card
        position = image.position
        file = image.file
        created = image.created
    }

    /// Drop the locally-cached pre-cached JPEG bytes so SwiftData reclaims the
    /// `.externalStorage` sidecar file. Called on sign-out before the mirror's
    /// bulk delete so a previous user's cached image bytes don't survive as
    /// orphaned sidecars in the shared store directory (SEC-2).
    func clearCachedBlob() {
        blob = Data()
        isCached = false
        blobETag = nil
    }
}

extension LocalCardCompletion {
    var asCardCompletion: CardCompletion {
        CardCompletion(
            id: id, card: card, user: user,
            state: CardCompletion.State(rawValue: stateRaw) ?? .pending,
            changedAt: changedAt
        )
    }
}
