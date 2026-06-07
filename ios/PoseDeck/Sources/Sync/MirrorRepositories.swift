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
    /// The authenticated user's id — used to owner-scope the Trash so a guest
    /// never sees/restores an owner's trashed shared deck (`[FIX #3-iOS]`).
    let currentUserId: String
    /// Optional image repository used to copy a source card's images onto the
    /// duplicated card (item 4), best-effort. Defaulted to `nil` so call sites
    /// that don't need image-copy (and tests) keep compiling and skip it.
    let imageRepo: ImageRepositing?

    init(
        store: SwiftDataLocalStore,
        outbox: SwiftDataOutbox,
        currentUserId: String,
        now: @escaping @Sendable () -> Date = { Date() },
        imageRepo: ImageRepositing? = nil
    ) {
        self.store = store
        self.outbox = outbox
        self.currentUserId = currentUserId
        self.writePath = OfflineWritePath(store: store, outbox: outbox, now: now)
        self.now = now
        self.imageRepo = imageRepo
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
        // `[FIX #3-iOS]`: owner-scope the Trash. The decks listRule grants a guest
        // visibility into an owner's trashed shared decks, so without this filter
        // a guest's Trash would surface (and could issue an illegal restore PATCH
        // that 403s on) a deck they don't own. Only the current user's own
        // soft-deleted decks belong in their Trash.
        await store.allDecks()
            .filter { $0.deletedAt != nil && $0.owner == currentUserId }
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
        let priorDeletedAt = deck.deletedAt
        let stamp = now()
        var updated = deck
        updated.deletedAt = nil
        updated.clientUpdatedAt = stamp
        await store.upsertDeck(updated)
        // Reverse the local cascade hide: un-hide ONLY children the deck cascade
        // hid (their deleted_at == the deck's prior deleted_at), so a card the
        // user individually trashed before the deck was trashed stays trashed.
        // Shares the exact predicate with SyncEngine.cascadeDeckRestore via the
        // pure DeckCascade helper so the optimistic and realtime paths agree.
        let children = await store.cards(deckId: id)
        for childId in DeckCascade.childIdsToUnhideOnRestore(cards: children, hiddenAt: priorDeletedAt) {
            await store.unhideCard(id: childId)
        }
        try await outbox.enqueueWireUpdate(entity: "decks", body: DeckRestoreWire(
            id: id, deleted_at: "", client_updated_at: PocketBaseDate.string(from: stamp)
        ), now: now())
        return await store.deck(id: id) ?? updated
    }

    /// Duplicate a deck **offline-first**: mint the copy locally + enqueue a deck
    /// create, then copy each non-deleted card with a fresh client id at striped
    /// positions (mirrors ``DeckRepository/duplicateDeck`` but through the outbox).
    ///
    /// When an ``ImageRepositing`` is injected, each copied card's images are also
    /// copied **best-effort** (item 4): per source image, the bytes are fetched
    /// through the protected, non-persisting session (SEC-IOS-B) and re-uploaded
    /// onto the copy card. The upload is network-bound and the copy card's
    /// server-side record only exists once its outbox `create` has flushed, so —
    /// like the web online-after-drain step — an image copy that races ahead of
    /// the card's sync simply fails and is skipped. Every image copy runs in its
    /// own `do`/`catch`; one failure is logged and skipped and never fails the
    /// duplicate (the cards always copy regardless).
    @discardableResult
    func duplicateDeck(id: String, ownerId: String) async throws -> Deck {
        guard let source = await store.deck(id: id), source.deletedAt == nil else {
            throw DeckRepositoryError.notFound(id: id)
        }
        // Clamp the copy name to the DB ceiling (ARCHITECTURE.md §3.2, max 200)
        // before appending " (copy)" so the suffix survives and the enqueued
        // create is never server-rejected — mirrors DeckRepository.duplicateDeck
        // and the web deckApi.ts. OfflineWritePath.createDeck also clamps as a
        // backstop, but clamping the base here keeps the " (copy)" suffix intact.
        let suffix = " (copy)"
        let base = String(source.name.prefix(DeckRepository.nameMaxLength - suffix.count))
        let copy = try await writePath.createDeck(name: base + suffix, shootDate: nil, ownerId: ownerId)
        let sourceCards = await store.cards(deckId: id).filter { $0.deletedAt == nil }
        for card in sourceCards {
            let fields = CardRepository.CardFields(
                title: card.title, timeSlot: card.timeSlot, subjects: card.subjects,
                direction: card.direction, notes: card.notes
            )
            let copyCard = try await writePath.createCard(deckId: copy.id, fields: fields)
            if let imageRepo {
                await copyImages(from: card, to: copyCard, using: imageRepo)
            }
        }
        return copy
    }

    /// Best-effort copy of every image on `source` onto `destination`, preserving
    /// each image's position. Each image is handled in its own `do`/`catch`: a
    /// failed list/token-mint/download/upload (including the per-card cap throwing
    /// or the copy card not yet existing server-side) is skipped so a single bad
    /// image never aborts the duplicate or the remaining images. Bytes are fetched
    /// through the protected non-persisting session (SEC-IOS-B), NOT
    /// `URLSession.shared`, so the already-compressed JPEG is re-uploaded without
    /// ever touching the shared on-disk HTTP cache.
    private func copyImages(from source: Card, to destination: Card, using imageRepo: ImageRepositing) async {
        let sourceImages: [CardImage]
        do {
            sourceImages = try await imageRepo.listCardImages(cardId: source.id)
        } catch {
            return
        }
        for image in sourceImages {
            do {
                let url = try await imageRepo.fileURL(for: image)
                let data = try await MirrorDeckRepository.downloadProtected(url)
                _ = try await imageRepo.uploadCardImage(
                    cardId: destination.id,
                    data: data,
                    position: image.position
                )
            } catch {
                continue
            }
        }
    }

    /// Download protected image bytes through the dedicated non-persisting session
    /// (SEC-IOS-B) so decrypted private `card_images` bytes never reach
    /// `URLCache.shared`. A static holder keeps one session for all copies.
    private static let protectedSession = ProtectedImageSession.make()
    private static func downloadProtected(_ url: URL) async throws -> Data {
        try await protectedSession.data(from: url).0
    }
}

// MARK: - Deck guests (sharing)

/// Mirror-backed deck-guest repository (M5 sharing). Reads serve the local
/// mirror (deck-scoped); `grantGuest` resolves the email to a user id via the
/// network ``DeckGuestRepository`` then writes optimistically + enqueues through
/// the shared ``OfflineWritePath``; `revokeGuest` hard-removes the mirror row +
/// enqueues a delete. Email resolution is network-bound (the server holds the
/// users table); the grant/revoke writes themselves are offline-first.
@MainActor
struct MirrorDeckGuestRepository: DeckGuestRepositoring {
    let store: SwiftDataLocalStore
    let outbox: SwiftDataOutbox
    let writePath: OfflineWritePath
    let remote: DeckGuestRepository

    init(
        store: SwiftDataLocalStore,
        outbox: SwiftDataOutbox,
        currentUserId: String,
        apiClient: APIClient,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.outbox = outbox
        self.writePath = OfflineWritePath(store: store, outbox: outbox, now: now)
        self.remote = DeckGuestRepository(client: apiClient, currentUserId: currentUserId)
    }

    func listGuests(deckId: String) async throws -> [DeckGuest] {
        await store.deckGuests(deckId: deckId)
    }

    @discardableResult
    func grantGuest(deckId: String, email: String) async throws -> DeckGuest {
        guard let userId = try await remote.resolveUser(byEmail: email) else {
            throw DeckGuestRepositoringError.userNotFound
        }
        return try await writePath.grantGuest(deckId: deckId, userId: userId)
    }

    func revokeGuest(_ guest: DeckGuest) async throws {
        try await writePath.revokeGuest(guest)
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

// MARK: - Card completions (per-user shoot progress)

/// Mirror-backed completion repository. Reads serve the local mirror
/// (deck-scoped via card ids); writes route through the shared ``OfflineWritePath``
/// so the optimistic mirror write + the exact PocketBase wire body live in one
/// audited place (mirroring the deck/card repos). `markDone`→`.done`,
/// `markSkipped`→`.skipped`, `clearCompletion`→`.pending`.
@MainActor
struct MirrorCardCompletionRepository: CardCompletionRepositoring {
    let store: SwiftDataLocalStore
    let outbox: SwiftDataOutbox
    let writePath: OfflineWritePath

    init(
        store: SwiftDataLocalStore,
        outbox: SwiftDataOutbox,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.outbox = outbox
        self.writePath = OfflineWritePath(store: store, outbox: outbox, now: now)
    }

    func completions(forCardIds cardIds: [String], userId: String) async throws -> [CardCompletion] {
        await store.cardCompletions(cardIds: cardIds).filter { $0.user == userId }
    }

    @discardableResult
    func markDone(cardId: String, userId: String) async throws -> CardCompletion {
        try await writePath.markCardCompletion(cardId: cardId, userId: userId, state: .done)
    }

    @discardableResult
    func markSkipped(cardId: String, userId: String) async throws -> CardCompletion {
        try await writePath.markCardCompletion(cardId: cardId, userId: userId, state: .skipped)
    }

    @discardableResult
    func clearCompletion(cardId: String, userId: String) async throws -> CardCompletion {
        try await writePath.markCardCompletion(cardId: cardId, userId: userId, state: .pending)
    }

    /// Reset every supplied completion back to `pending` so a finished deck can be
    /// re-shot (item 3). There is no bulk completion write, so loop
    /// `markCardCompletion(.pending)` per id: each call writes the deterministic
    /// `(card, user)`-keyed row (LWW / `changed_at`-convergent, coalescing) and
    /// `applyLocalCardCompletion` updates the local mirror synchronously, so when
    /// this method returns the local mirror reads `pending` for all supplied ids.
    func resetCompletions(forCardIds cardIds: [String], userId: String) async throws {
        for cardId in cardIds {
            _ = try await writePath.markCardCompletion(cardId: cardId, userId: userId, state: .pending)
        }
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
        // Reconcile against remote on every read when online (swift-5): card_images
        // carry no LWW clock and no resync backfills them, so realtime was the only
        // path that could adopt a remotely-added image or drop a remotely-deleted
        // one. Short-circuiting on a non-empty mirror left a second device (or a
        // missed realtime event) serving a stale row — a missing thumbnail or a 404
        // token URL for a server-deleted image. Always fetch + reconcile here so a
        // reload converges the mirror onto the server truth.
        //
        // If the fetch fails (offline / transient), DO NOT treat it as "remote is
        // empty" — that would evict every mirrored row. Fall back to serving the
        // mirror as-is (offline-first, ARCHITECTURE.md §4.1).
        guard let remoteImages = try? await remote.listCardImages(cardId: cardId) else {
            return await store.cardImages(cardId: cardId)
        }
        return await CardImageReconciler.apply(remote: remoteImages, to: store, cardId: cardId)
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
