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
    /// Test-only fault injector invoked inside ``enqueue(_:entity:body:)`` just
    /// before the entry is appended, so a test can simulate the (narrow but real)
    /// case where an enqueue fails mid-loop — payload encode error or a persistent
    /// outbox save error — and assert the mirror rolls back. Always `nil` in
    /// production. `[CORR-2]`
    private let enqueueFault: (@Sendable (_ cardId: String) async throws -> Void)?

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
        self.enqueueFault = nil
    }

    /// Test-only initializer that wires a fault injector into the enqueue path.
    /// `[CORR-2]`
    init(
        store: any LocalStore,
        outbox: OutboxQueue,
        now: @escaping @Sendable () -> Date,
        newId: @escaping @Sendable () -> String,
        enqueueFault: @escaping @Sendable (_ cardId: String) async throws -> Void
    ) {
        self.store = store
        self.outbox = outbox
        self.now = now
        self.newId = newId
        self.encoder = PocketBaseDate.makeEncoder()
        self.enqueueFault = enqueueFault
    }

    // MARK: - Decks

    /// Create a deck locally + enqueue. Returns the optimistic ``Deck`` (with the
    /// client-minted id) so the UI can navigate immediately.
    ///
    /// `name` is clamped to the DB ceiling (``DeckRepository/nameMaxLength``,
    /// ARCHITECTURE.md §3.2 max 200) here so EVERY offline create — a direct
    /// create or a `duplicateDeck` " (copy)" name — is protected at one audited
    /// chokepoint. Without this, an over-long name would write an optimistic
    /// local row but produce an outbox create the server 4xxes and drops, leaving
    /// a silent ghost deck (and any enqueued child copies referencing it) that
    /// never syncs. Matches the clamp in ``DeckRepository/duplicateDeck`` and the
    /// web `deckApi.ts` reference.
    @discardableResult
    public func createDeck(name: String, shootDate: Date? = nil, ownerId: String) async throws -> Deck {
        let id = newId()
        let stamp = now()
        let name = String(name.prefix(DeckRepository.nameMaxLength))
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
    ///
    /// `name` is clamped to the DB ceiling (``DeckRepository/nameMaxLength``,
    /// ARCHITECTURE.md §3.2 max 200) — same chokepoint discipline as
    /// ``createDeck(name:shootDate:ownerId:)`` so an over-long rename never
    /// writes an optimistic local row whose outbox update the server 4xxes and
    /// drops (web `deckApi.ts` `maxLength={200}` parity).
    public func renameDeck(_ deck: Deck, name: String) async throws {
        let name = String(name.prefix(DeckRepository.nameMaxLength))
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
    ///
    /// The child cascade mirrors ``SyncEngine``'s realtime path: each child
    /// card's images are hard-removed and the card is display-hidden via
    /// ``LocalStore/hideCard(id:deletedAt:)`` sharing the deck's own `stamp`.
    /// Hiding deliberately leaves each child's `client_updated_at` (its real LWW
    /// clock) untouched — the server never soft-deletes cards on a deck delete
    /// (web parity: `deckApi.softDeleteDeck` patches only the deck row), so we
    /// must not fabricate a future client clock for the children. Only the deck
    /// row is enqueued; the server-side cascade + realtime echo carry the rest.
    public func softDeleteDeck(_ deck: Deck) async throws {
        // [CORR-IOS-1] Stamp at the SAME precision the server/realtime echo will
        // carry. The wire format (`PocketBaseDate.wireFormat`, `.SSS`) is
        // millisecond-resolution and `DateFormatter` *rounds* sub-millisecond
        // fractions, so a raw in-memory `now()` and its wire round-trip differ by
        // up to ~0.5ms. If we stamped the deck + children with the raw full-precision
        // `now()` but the later deck-update echo upserts the deck row at the
        // round-tripped (ms) precision, the deck's `deletedAt` would no longer equal
        // the children's, and the restore cascade — which un-hides children whose
        // `deletedAt` exactly equals the deck's prior `deletedAt` — would un-hide
        // nothing, restoring the deck with all its cards still hidden. Round-tripping
        // the stamp here makes the offline write already match the wire precision, so
        // deck and child `deletedAt` stay equal regardless of which path last touched
        // the deck row.
        let raw = now()
        let stamp = PocketBaseDate.date(from: PocketBaseDate.string(from: raw)) ?? raw
        var updated = deck
        updated.deletedAt = stamp
        updated.clientUpdatedAt = stamp
        await store.upsertDeck(updated)

        // Cascade the hide to children locally (invariant: deck soft-delete
        // evicts children locally), matching SyncEngine.cascadeDeckRemoval.
        let children = await store.cards(deckId: deck.id)
        for card in children {
            let images = await store.cardImages(cardId: card.id)
            for image in images {
                await store.hardDeleteCardImage(id: image.id)
            }
            if card.deletedAt == nil {
                await store.hideCard(id: card.id, deletedAt: stamp)
            }
        }

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
    ///
    /// [CORR-2] Atomic over the mirror: every moved card's optimistic upsert is
    /// paired with its outbox enqueue inside the loop, so a mid-loop throw (e.g.
    /// an `enqueue` whose payload fails to encode or whose persistent save
    /// errors) would otherwise leave the store in a neither-old-nor-new restripe
    /// that a later `load()`/`refresh()` re-surfaces — the view-model's in-memory
    /// revert (``CardRepository/restoredOrder``) does NOT undo the store. To keep
    /// the local mirror all-or-nothing, we capture each card's original
    /// `(position, clientUpdatedAt)` before mutating it; on a thrown error we
    /// re-upsert the captured originals (in reverse order) before rethrowing, so
    /// the store ends in the exact pre-reorder state.
    @discardableResult
    public func reorderCards(deckId: String, orderedIds: [String]) async throws -> [String] {
        let stamp = now()
        let stampString = PocketBaseDate.string(from: stamp)
        var enqueued: [String] = []
        // Captured originals (newest-applied last) so a mid-loop failure can roll
        // the mirror back to its exact pre-reorder state.
        var applied: [Card] = []
        do {
            for (id, position) in CardRepository.computeReorderedPositions(orderedIds: orderedIds) {
                guard let card = await store.card(id: id) else { continue }
                if card.position == position { continue } // unmoved → skip
                var moved = card
                moved.position = position
                moved.clientUpdatedAt = stamp
                await store.upsertCard(moved)
                applied.append(card) // capture the pre-mutation row for rollback
                // [CORR-2] Test-only fault point: simulate an enqueue that fails
                // *after* this card's optimistic store write landed.
                try await enqueueFault?(id)
                let body = CardReorderWire(
                    id: id,
                    position: position,
                    client_updated_at: stampString
                )
                try await enqueue(.update, entity: "cards", body: body)
                enqueued.append(id)
            }
        } catch {
            // Roll the mirror back to the pre-reorder snapshot before rethrowing so
            // the catch path's in-memory revert and the persisted store agree.
            // restoreCard (not upsertCard) is required: each moved row in the store
            // now carries a fresher reorder clock, so re-applying the older original
            // through the LWW upsert would be rejected and the partial restripe would
            // survive. Reverse order is immaterial (ids are distinct).
            for original in applied.reversed() {
                await store.restoreCard(original)
            }
            throw error
        }
        return enqueued
    }

    // MARK: - Card completions (per-user shoot progress; LWW on changedAt)

    /// Mark a `(card, user)` completion to `state` locally + enqueue.
    ///
    /// The record id is **deterministic** (`CardCompletion.deterministicId`), so
    /// the same `(card, user)` always maps to the same row across devices and
    /// replays. This makes the first mark an idempotent `.create` and every
    /// later state flip a `.update` PATCH on the same id.
    ///
    /// Create-vs-update branches on whether the row already exists in the local
    /// mirror (`store.cardCompletion(id:) == nil`). With `[FIX-C1]` the create
    /// path is safe even when the mirror is wrong about server existence: the
    /// server's composite-unique constraint rejects the duplicate id and
    /// ``MutationSender`` issues a follow-up state PATCH rather than dropping the
    /// change.
    ///
    /// The optimistic local write goes through ``LocalStore/applyLocalCardCompletion(_:)``
    /// (NOT the LWW `upsert`) so a user's own action is never a tie no-op
    /// (`[FIX-M1]`). Each enqueue gets a fresh `idempotencyKey` — distinct state
    /// changes must both send; the stable key is the record id, not the outbox key.
    @discardableResult
    public func markCardCompletion(
        cardId: String,
        userId: String,
        state: CardCompletion.State
    ) async throws -> CardCompletion {
        let id = CardCompletion.deterministicId(card: cardId, user: userId)
        let stamp = now()
        let completion = CardCompletion(
            id: id,
            card: cardId,
            user: userId,
            state: state,
            changedAt: stamp
        )

        let exists = await store.cardCompletion(id: id) != nil
        // `[FIX-M1]`: force-apply the user's own action, bypassing the LWW tie guard.
        await store.applyLocalCardCompletion(completion)

        let stampString = PocketBaseDate.string(from: stamp)
        if exists {
            let body = CardCompletionUpdateWire(
                id: id,
                state: state.rawValue,
                changed_at: stampString
            )
            try await enqueue(.update, entity: "card_completions", body: body)
        } else {
            let body = CardCompletionUpsertWire(
                id: id,
                card: cardId,
                user: userId,
                state: state.rawValue,
                changed_at: stampString
            )
            try await enqueue(.create, entity: "card_completions", body: body)
        }
        return completion
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

    /// Grant a guest access to a deck: mint a client id, write the optimistic
    /// ``DeckGuest`` into the mirror immediately, and enqueue a `.create`.
    ///
    /// Mirrors ``createCard``'s no-LWW insert (grants carry no `client_updated_at`).
    /// A re-grant racing an existing `(deck, user)` row hits the server's
    /// composite-unique constraint and 400s — ``MutationSender`` classifies a
    /// `deck_guests` create 400 as idempotent success (`[FIX #6-iOS]`), so the
    /// optimistic row is kept and no error surfaces. Returns the optimistic
    /// ``DeckGuest`` so the share UI can reflect it at once.
    @discardableResult
    public func grantGuest(deckId: String, userId: String) async throws -> DeckGuest {
        let id = newId()
        let stamp = now()
        let guest = DeckGuest(id: id, deck: deckId, user: userId, grantedAt: stamp)
        await store.upsertDeckGuest(guest)
        let body = DeckGuestCreateWire(
            id: id,
            deck: deckId,
            user: userId,
            granted_at: PocketBaseDate.string(from: stamp)
        )
        try await enqueue(.create, entity: "deck_guests", body: body)
        return guest
    }

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
    /// Deck-guest grant body (carries the client-minted id; no LWW clock).
    struct DeckGuestCreateWire: Encodable, Sendable {
        let id: String
        let deck: String
        let user: String
        let granted_at: String
    }
    /// Full completion create body (carries the deterministic client id).
    struct CardCompletionUpsertWire: Encodable, Sendable {
        let id: String
        let card: String
        let user: String
        let state: String
        let changed_at: String
    }
    /// Completion state-flip PATCH body.
    struct CardCompletionUpdateWire: Encodable, Sendable {
        let id: String
        let state: String
        let changed_at: String
    }
}
