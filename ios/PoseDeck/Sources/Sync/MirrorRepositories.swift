import Foundation
import PoseDeckCore

/// Offline-first repositories that read from the SwiftData mirror and write
/// optimistically + enqueue to the outbox (M3 plan, STEP 10).
///
/// These conform to the same app-side protocols (`DeckRepositoring`,
/// `CardRepositoring`, `CardImageReading`, `ImageRepositing`) the view models
/// already depend on, so wiring them is a swap at the composition root — no view
/// model rewrite beyond changing concrete-type references to the protocol.
///
/// Writes route through the shared PoseDeckCore ``OfflineWritePath`` where it has
/// a method (so the mirror write + the exact PocketBase wire body live in one
/// audited place); the few write paths it doesn't cover (set-date, restore,
/// duplicate, partial card update) are handled here against the same store +
/// outbox using PocketBase-shaped wire bodies.
///
/// Reads serve the mirror directly: live (non-soft-deleted) rows for the main
/// views, soft-deleted rows for trash. Image reads serve a cached blob first and
/// fall back to a freshly-minted token URL.

// MARK: - Decks

@MainActor
struct MirrorDeckRepository: DeckRepositoring {
    let store: SwiftDataLocalStore
    let outbox: SwiftDataOutbox
    let writePath: OfflineWritePath
    let now: @Sendable () -> Date

    init(
        store: SwiftDataLocalStore,
        outbox: SwiftDataOutbox,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.outbox = outbox
        self.writePath = OfflineWritePath(store: store, outbox: outbox, now: now)
        self.now = now
    }

    // Reads (mirror)

    func listDecks() async throws -> [Deck] {
        await store.allDecks()
            .filter { $0.deletedAt == nil }
            .sorted { ($0.updated ?? $0.clientUpdatedAt ?? .distantPast) > ($1.updated ?? $1.clientUpdatedAt ?? .distantPast) }
    }

    func getDeck(id: String) async throws -> Deck {
        guard let deck = await store.deck(id: id), deck.deletedAt == nil else {
            throw DeckRepositoryError.notFound(id: id)
        }
        return deck
    }

    func listTrashedDecks() async throws -> [Deck] {
        await store.allDecks()
            .filter { $0.deletedAt != nil }
            .sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
    }

    // Writes (optimistic + enqueue)

    @discardableResult
    func createDeck(name: String, shootDate: Date?, ownerId: String) async throws -> Deck {
        try await writePath.createDeck(name: name, shootDate: shootDate, ownerId: ownerId)
    }

    @discardableResult
    func renameDeck(id: String, name: String) async throws -> Deck {
        guard let deck = await store.deck(id: id) else { throw DeckRepositoryError.notFound(id: id) }
        try await writePath.renameDeck(deck, name: name)
        return await store.deck(id: id) ?? deck
    }

    @discardableResult
    func setShootDate(id: String, shootDate: Date?) async throws -> Deck {
        guard let deck = await store.deck(id: id) else { throw DeckRepositoryError.notFound(id: id) }
        let stamp = now()
        var updated = deck
        updated.shootDate = shootDate
        updated.clientUpdatedAt = stamp
        await store.upsertDeck(updated)
        try await outbox.enqueueWireUpdate(entity: "decks", body: DeckShootDateWire(
            id: id,
            shoot_date: shootDate.map(PocketBaseDate.string(from:)) ?? "",
            client_updated_at: PocketBaseDate.string(from: stamp)
        ), now: now())
        return await store.deck(id: id) ?? updated
    }

    @discardableResult
    func softDeleteDeck(id: String) async throws -> Deck {
        guard let deck = await store.deck(id: id) else { throw DeckRepositoryError.notFound(id: id) }
        try await writePath.softDeleteDeck(deck)
        return await store.deck(id: id) ?? deck
    }

    @discardableResult
    func restoreDeck(id: String) async throws -> Deck {
        guard let deck = await store.deck(id: id) else { throw DeckRepositoryError.notFound(id: id) }
        let stamp = now()
        var updated = deck
        updated.deletedAt = nil
        updated.clientUpdatedAt = stamp
        await store.upsertDeck(updated)
        try await outbox.enqueueWireUpdate(entity: "decks", body: DeckRestoreWire(
            id: id, deleted_at: "", client_updated_at: PocketBaseDate.string(from: stamp)
        ), now: now())
        return await store.deck(id: id) ?? updated
    }

    /// Duplicate a deck **offline-first**: mint the copy locally + enqueue a deck
    /// create, then copy each non-deleted card with a fresh client id at striped
    /// positions (mirrors ``DeckRepository/duplicateDeck`` but through the outbox).
    @discardableResult
    func duplicateDeck(id: String, ownerId: String) async throws -> Deck {
        guard let source = await store.deck(id: id), source.deletedAt == nil else {
            throw DeckRepositoryError.notFound(id: id)
        }
        let copy = try await writePath.createDeck(name: "\(source.name) (copy)", shootDate: nil, ownerId: ownerId)
        let sourceCards = await store.cards(deckId: id).filter { $0.deletedAt == nil }
        for card in sourceCards {
            let fields = CardRepository.CardFields(
                title: card.title, timeSlot: card.timeSlot, subjects: card.subjects,
                direction: card.direction, notes: card.notes
            )
            try await writePath.createCard(deckId: copy.id, fields: fields)
        }
        return copy
    }
}

// MARK: - Cards

@MainActor
struct MirrorCardRepository: CardRepositoring {
    let store: SwiftDataLocalStore
    let outbox: SwiftDataOutbox
    let writePath: OfflineWritePath
    let now: @Sendable () -> Date

    init(
        store: SwiftDataLocalStore,
        outbox: SwiftDataOutbox,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.outbox = outbox
        self.writePath = OfflineWritePath(store: store, outbox: outbox, now: now)
        self.now = now
    }

    func listCards(deckId: String) async throws -> [Card] {
        await store.cards(deckId: deckId).filter { $0.deletedAt == nil }
    }

    @discardableResult
    func createCard(deckId: String, fields: CardRepository.CardFields) async throws -> Card {
        try await writePath.createCard(deckId: deckId, fields: fields)
    }

    @discardableResult
    func updateCard(id: String, fields: CardRepository.PartialCardFields) async throws -> Card {
        guard let card = await store.card(id: id) else { throw DeckRepositoryError.notFound(id: id) }
        let stamp = now()
        var updated = card
        if let title = fields.title { updated.title = String(title.prefix(CardRepository.titleMaxLength)) }
        if let v = fields.timeSlot { updated.timeSlot = v }
        if let v = fields.subjects { updated.subjects = v }
        if let v = fields.direction { updated.direction = v }
        if let v = fields.notes { updated.notes = v }
        updated.clientUpdatedAt = stamp
        await store.upsertCard(updated)
        try await outbox.enqueueWireUpdate(entity: "cards", body: CardUpdateWire(
            id: id,
            title: fields.title.map { String($0.prefix(CardRepository.titleMaxLength)) },
            time_slot: fields.timeSlot,
            subjects: fields.subjects,
            direction: fields.direction,
            notes: fields.notes,
            client_updated_at: PocketBaseDate.string(from: stamp)
        ), now: now())
        return await store.card(id: id) ?? updated
    }

    @discardableResult
    func softDeleteCard(id: String) async throws -> Card {
        guard let card = await store.card(id: id) else { throw DeckRepositoryError.notFound(id: id) }
        try await writePath.softDeleteCard(card)
        return await store.card(id: id) ?? card
    }

    func reorderCards(deckId: String, orderedIds: [String], currentPositions: [String: Int]?) async throws {
        _ = try await writePath.reorderCards(deckId: deckId, orderedIds: orderedIds)
    }
}

// MARK: - Images

/// Mirror-backed image repository. Reads serve a cached `blob` first (offline)
/// and fall back to a token URL; writes (upload / delete) go to the network via
/// the wrapped concrete ``ImageRepository`` and then mirror their result. Upload
/// stays network-bound (multipart, server-minted file) — offline upload queueing
/// is deferred; deletes enqueue through the outbox so they survive offline.
@MainActor
struct MirrorImageRepository: ImageRepositing, CardImageReading {
    let store: SwiftDataLocalStore
    let outbox: SwiftDataOutbox
    nonisolated let remote: ImageRepository

    nonisolated var maxImagesPerCard: Int { remote.maxImagesPerCard }

    init(store: SwiftDataLocalStore, outbox: SwiftDataOutbox, remote: ImageRepository) {
        self.store = store
        self.outbox = outbox
        self.remote = remote
    }

    func listCardImages(cardId: String) async throws -> [CardImage] {
        // Serve the mirror if it has rows; otherwise hit the network and adopt.
        let mirrored = await store.cardImages(cardId: cardId)
        if !mirrored.isEmpty { return mirrored }
        let remoteImages = (try? await remote.listCardImages(cardId: cardId)) ?? []
        for image in remoteImages { await store.upsertCardImage(image) }
        return remoteImages
    }

    @discardableResult
    func uploadCardImage(cardId: String, data: Data, position: Int) async throws -> CardImage {
        // Upload is network-bound (server mints the file + record id); mirror the
        // created record so reads stay coherent. Offline upload queueing is out
        // of scope for M3 (deferred), matching the web "PB-direct upload" choice.
        let created = try await remote.uploadCardImage(cardId: cardId, data: data, position: position)
        await store.upsertCardImage(created)
        return created
    }

    func deleteCardImage(id: String) async throws {
        // Optimistic local hard-delete + enqueue (survives offline).
        if let image = await store.cardImage(id: id) {
            try await OfflineWritePath(store: store, outbox: outbox).deleteCardImage(image)
        } else {
            // Not in mirror: enqueue a delete by id so the server still removes it.
            try await outbox.enqueueWireDelete(entity: "card_images", id: id)
        }
    }

    func fileURL(for image: CardImage) async throws -> URL {
        // Cached-blob-first is owned by the view layer (an OfflineImage component
        // would serve `blob`); here we always return a fresh token URL so an
        // online AsyncImage works. The blob is consulted by the precache/offline
        // render path, not this URL minting.
        try await remote.fileURL(for: image)
    }
}

// MARK: - Outbox wire-enqueue helpers

extension SwiftDataOutbox {
    /// Encode `body` as a PATCH update payload and enqueue it.
    func enqueueWireUpdate<Body: Encodable & Sendable>(entity: String, body: Body, now: Date) async throws {
        let payload = try PocketBaseDate.makeEncoder().encode(body)
        await enqueue(OutboxEntry(type: .update, entity: entity, payload: payload, localTimestamp: now))
    }

    /// Enqueue a DELETE-by-id payload.
    func enqueueWireDelete(entity: String, id: String) async throws {
        struct IdOnly: Encodable { let id: String }
        let payload = try PocketBaseDate.makeEncoder().encode(IdOnly(id: id))
        await enqueue(OutboxEntry(type: .delete, entity: entity, payload: payload, localTimestamp: Date()))
    }
}

// MARK: - Wire bodies for the write paths OfflineWritePath doesn't cover

private struct DeckShootDateWire: Encodable, Sendable {
    let id: String
    let shoot_date: String
    let client_updated_at: String
}

private struct DeckRestoreWire: Encodable, Sendable {
    let id: String
    let deleted_at: String
    let client_updated_at: String
}

/// Sparse card PATCH body: omit nil keys so the update only writes provided
/// fields. `id` and `client_updated_at` are always present.
private struct CardUpdateWire: Encodable, Sendable {
    let id: String
    let title: String?
    let time_slot: String?
    let subjects: String?
    let direction: String?
    let notes: String?
    let client_updated_at: String

    enum CodingKeys: String, CodingKey {
        case id, title, time_slot, subjects, direction, notes, client_updated_at
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        if let title { try c.encode(title, forKey: .title) }
        if let time_slot { try c.encode(time_slot, forKey: .time_slot) }
        if let subjects { try c.encode(subjects, forKey: .subjects) }
        if let direction { try c.encode(direction, forKey: .direction) }
        if let notes { try c.encode(notes, forKey: .notes) }
        try c.encode(client_updated_at, forKey: .client_updated_at)
    }
}
