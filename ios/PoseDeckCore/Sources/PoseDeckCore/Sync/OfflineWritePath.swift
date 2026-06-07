import Foundation

/// The offline-first write path for the synced collections (M3 plan, STEP 8 /
/// ARCHITECTURE.md §4.2 steps 2–3).
///
/// Each mutation here is local-first: it (1) mints a client-supplied id for
/// creates, (2) writes the optimistic row into the ``LocalStore`` *immediately*,
/// and (3) appends an ``OutboxEntry`` carrying the exact PocketBase wire body
/// the ``MutationSender`` will POST/PATCH/DELETE. No network call happens on the
/// calling path — the ``OutboxProcessor`` drains the queue asynchronously.
///
/// This is the piece the repos previously lacked (their CRUD went straight to
/// the network). It deliberately lives beside ``DeckRepository`` /
/// ``CardRepository`` rather than replacing their direct-network methods so the
/// existing wire-payload contract (and its tests) stays intact; the app's
/// offline mutations route through here.
///
/// Payloads are encoded once, here, in PocketBase wire shape (snake_case keys,
/// wire-format datetimes, client-supplied `id` on create) so the sender ships
/// them verbatim and the LocalStore mirror matches what the server will store.
public struct OfflineWritePath: Sendable {

    private let store: any LocalStore
    private let outbox: OutboxQueue
    private let now: @Sendable () -> Date
    private let newId: @Sendable () -> String
    private let encoder: JSONEncoder

    public init(
        store: any LocalStore,
        outbox: OutboxQueue,
        now: @escaping @Sendable () -> Date = Date.init,
        newId: @escaping @Sendable () -> String = IDGenerator.newClientId
    ) {
        self.store = store
        self.outbox = outbox
        self.now = now
        self.newId = newId
        self.encoder = PocketBaseDate.makeEncoder()
    }

    // MARK: - Decks

    /// Create a deck locally + enqueue. Returns the optimistic ``Deck`` (with the
    /// client-minted id) so the UI can navigate immediately.
    @discardableResult
    public func createDeck(name: String, shootDate: Date? = nil, ownerId: String) async throws -> Deck {
        let id = newId()
        let stamp = now()
        let deck = Deck(
            id: id,
            owner: ownerId,
            name: name,
            shootDate: shootDate,
            clientUpdatedAt: stamp,
            deletedAt: nil
        )
        await store.upsertDeck(deck)

        let body = DeckCreateWire(
            id: id,
            owner: ownerId,
            name: name,
            shoot_date: shootDate.map(PocketBaseDate.string(from:)) ?? "",
            deleted_at: "",
            client_updated_at: PocketBaseDate.string(from: stamp)
        )
        try await enqueue(.create, entity: "decks", body: body)
        return deck
    }

    /// Rename a deck locally + enqueue.
    public func renameDeck(_ deck: Deck, name: String) async throws {
        var updated = deck
        updated.name = name
        updated.clientUpdatedAt = now()
        await store.upsertDeck(updated)
        let body = DeckUpdateWire(
            id: deck.id,
            name: name,
            client_updated_at: PocketBaseDate.string(from: updated.clientUpdatedAt!)
        )
        try await enqueue(.update, entity: "decks", body: body)
    }

    /// Soft-delete a deck locally (set `deleted_at`) + enqueue, cascading the
    /// hide to the deck's children in the local mirror (invariant: deck
    /// soft-delete evicts children locally — also enforced by ``SyncEngine``).
    public func softDeleteDeck(_ deck: Deck) async throws {
        let stamp = now()
        var updated = deck
        updated.deletedAt = stamp
        updated.clientUpdatedAt = stamp
        await store.upsertDeck(updated)
        let body = DeckSoftDeleteWire(
            id: deck.id,
            deleted_at: PocketBaseDate.string(from: stamp),
            client_updated_at: PocketBaseDate.string(from: stamp)
        )
        try await enqueue(.update, entity: "decks", body: body)
    }

    // MARK: - Cards

    /// Create a card at the end of its deck locally + enqueue. Position is
    /// computed from the LocalStore mirror (not the network).
    @discardableResult
    public func createCard(deckId: String, fields: CardRepository.CardFields) async throws -> Card {
        let id = newId()
        let stamp = now()
        let existing = await store.cards(deckId: deckId)
        let position = CardRepository.nextPosition(after: existing)
        let card = Card(
            id: id,
            deck: deckId,
            position: position,
            title: fields.clampedTitle,
            timeSlot: fields.timeSlot,
            subjects: fields.subjects,
            direction: fields.direction,
            notes: fields.notes,
            clientUpdatedAt: stamp,
            deletedAt: nil
        )
        await store.upsertCard(card)
        let body = CardCreateWire(
            id: id,
            deck: deckId,
            position: position,
            title: fields.clampedTitle,
            time_slot: fields.timeSlot ?? "",
            subjects: fields.subjects ?? "",
            direction: fields.direction ?? "",
            notes: fields.notes ?? "",
            deleted_at: "",
            client_updated_at: PocketBaseDate.string(from: stamp)
        )
        try await enqueue(.create, entity: "cards", body: body)
        return card
    }

    /// Soft-delete a card locally + enqueue.
    public func softDeleteCard(_ card: Card) async throws {
        let stamp = now()
        var updated = card
        updated.deletedAt = stamp
        updated.clientUpdatedAt = stamp
        await store.upsertCard(updated)
        let body = CardSoftDeleteWire(
            id: card.id,
            deleted_at: PocketBaseDate.string(from: stamp),
            client_updated_at: PocketBaseDate.string(from: stamp)
        )
        try await enqueue(.update, entity: "cards", body: body)
    }

    /// Reorder a deck's cards as **one logical unit** (invariant #8): restripe to
    /// clean integer gaps, apply locally, and enqueue one update entry per moved
    /// card sharing a single `client_updated_at` stamp. Unmoved cards are
    /// skipped so a reorder never re-stamps a card it did not move.
    ///
    /// Returns the ids enqueued (the moved subset), so a caller that needs to
    /// re-derive a consistent restripe on a partial 4xx can do so.
    @discardableResult
    public func reorderCards(deckId: String, orderedIds: [String]) async throws -> [String] {
        let stamp = now()
        let stampString = PocketBaseDate.string(from: stamp)
        var enqueued: [String] = []
        for (id, position) in CardRepository.computeReorderedPositions(orderedIds: orderedIds) {
            guard let card = await store.card(id: id) else { continue }
            if card.position == position { continue } // unmoved → skip
            var moved = card
            moved.position = position
            moved.clientUpdatedAt = stamp
            await store.upsertCard(moved)
            let body = CardReorderWire(
                id: id,
                position: position,
                client_updated_at: stampString
            )
            try await enqueue(.update, entity: "cards", body: body)
            enqueued.append(id)
        }
        return enqueued
    }

    // MARK: - Card images (no LWW: insert / hard-delete)

    /// Enqueue a hard delete of a card image and remove it from the local mirror
    /// immediately. Images are hard-deleted (no soft-delete column).
    public func deleteCardImage(_ image: CardImage) async throws {
        await store.hardDeleteCardImage(id: image.id)
        let body = IdOnlyWire(id: image.id)
        try await enqueue(.delete, entity: "card_images", body: body)
    }

    // MARK: - Deck guests (no LWW: insert / hard-delete on revoke)

    /// Revoke a guest: hard-remove from the mirror + enqueue a delete.
    public func revokeGuest(_ guest: DeckGuest) async throws {
        await store.hardDeleteDeckGuest(id: guest.id)
        let body = IdOnlyWire(id: guest.id)
        try await enqueue(.delete, entity: "deck_guests", body: body)
    }

    // MARK: - Enqueue plumbing

    private func enqueue<Body: Encodable & Sendable>(
        _ type: OutboxMutationType,
        entity: String,
        body: Body
    ) async throws {
        let payload = try encoder.encode(body)
        let entry = OutboxEntry(
            type: type,
            entity: entity,
            payload: payload,
            localTimestamp: now()
        )
        await outbox.enqueue(entry)
    }

    // MARK: - Wire bodies (PocketBase shape; creates carry the client id)

    struct DeckCreateWire: Encodable, Sendable {
        let id: String
        let owner: String
        let name: String
        let shoot_date: String
        let deleted_at: String
        let client_updated_at: String
    }
    struct DeckUpdateWire: Encodable, Sendable {
        let id: String
        let name: String
        let client_updated_at: String
    }
    struct DeckSoftDeleteWire: Encodable, Sendable {
        let id: String
        let deleted_at: String
        let client_updated_at: String
    }
    struct CardCreateWire: Encodable, Sendable {
        let id: String
        let deck: String
        let position: Int
        let title: String
        let time_slot: String
        let subjects: String
        let direction: String
        let notes: String
        let deleted_at: String
        let client_updated_at: String
    }
    struct CardSoftDeleteWire: Encodable, Sendable {
        let id: String
        let deleted_at: String
        let client_updated_at: String
    }
    struct CardReorderWire: Encodable, Sendable {
        let id: String
        let position: Int
        let client_updated_at: String
    }
    struct IdOnlyWire: Encodable, Sendable {
        let id: String
    }
}
