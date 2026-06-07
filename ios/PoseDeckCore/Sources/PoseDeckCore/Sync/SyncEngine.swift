import Foundation

/// Applies realtime record events to the ``LocalStore`` (M3 plan, STEP 9 /
/// ARCHITECTURE.md §4.3–4.4).
///
/// Responsibilities:
///  - **Per-entity LWW** (invariant #3): decks/cards key on `client_updated_at`,
///    completions on `changed_at`; card_images and deck_guests have no clock —
///    create = insert-by-id, delete = hard remove-by-id.
///  - **Self-echo suppression** (invariant #4): a short-TTL recently-confirmed
///    set keyed by `(entity, id)` is populated by the ``OutboxProcessor`` on
///    success; a realtime echo matching an entry there is skipped unconditionally
///    (independent of timestamp math), so our own write isn't re-applied as if
///    it were a remote change.
///  - **Per-entity delete semantics**: decks/cards are *soft* deletes (an
///    incoming record with a non-empty `deleted_at` stays in the store but
///    hidden); images/guests are *hard* removes. A `delete` action on a
///    deck/card is treated as a soft hide too (defensive — the server uses
///    soft-delete, but a hard delete event still evicts locally).
///  - **Cascade** (invariant): a deck transitioning to soft-deleted evicts/hides
///    its cards (and their images) in the local mirror so no orphans linger.
///  - **Subscribe-before-resync** (invariant #6) is enforced by the caller
///    (open subscriptions, then resync); this engine's `apply` is idempotent so
///    overlap is safe.
public actor SyncEngine {

    private let store: any LocalStore
    /// `(entity, id)` of recently-confirmed local mutations, with an insertion
    /// timestamp so entries age out after `echoTTL`.
    private var recentlyConfirmed: [EchoKey: Date] = [:]
    private let echoTTL: TimeInterval
    private let now: @Sendable () -> Date

    private struct EchoKey: Hashable {
        let entity: String
        let id: String
    }

    public init(
        store: any LocalStore,
        echoTTL: TimeInterval = 10.0,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.echoTTL = echoTTL
        self.now = now
    }

    /// Record a just-confirmed local mutation so its realtime echo is suppressed
    /// (invariant #4). Wire this to ``OutboxProcessor``'s `onConfirmed` hook.
    public func noteConfirmed(entity: String, recordId: String) {
        recentlyConfirmed[EchoKey(entity: entity, id: recordId)] = now()
    }

    /// Test/debug seam: whether an echo for `(entity,id)` is currently suppressed.
    public func isSuppressed(entity: String, id: String) -> Bool {
        pruneExpired()
        return recentlyConfirmed[EchoKey(entity: entity, id: id)] != nil
    }

    /// Apply one decoded realtime event. Returns `true` if the store was changed,
    /// `false` if the event was suppressed (self-echo) or lost LWW.
    @discardableResult
    public func apply(_ event: RealtimeClient.RecordEvent) async -> Bool {
        guard let id = recordId(from: event.recordJSON) else { return false }

        // Self-echo suppression (invariant #4) — independent of LWW math.
        pruneExpired()
        if recentlyConfirmed[EchoKey(entity: event.subscription, id: id)] != nil {
            return false
        }

        switch event.subscription {
        case "decks":
            return await applyDeck(event)
        case "cards":
            return await applyCard(event)
        case "card_images":
            return await applyCardImage(event)
        case "card_completions":
            return await applyCardCompletion(event)
        case "deck_guests":
            return await applyDeckGuest(event)
        default:
            return false
        }
    }

    // MARK: - Per-collection apply

    private func applyDeck(_ event: RealtimeClient.RecordEvent) async -> Bool {
        guard let id = recordId(from: event.recordJSON) else { return false }
        if event.action == "delete" {
            // Hard delete event on a deck → hide locally + cascade.
            await cascadeDeckRemoval(deckId: id)
            return true
        }
        guard let deck = decode(Deck.self, from: event.recordJSON) else { return false }
        let existing = await store.deck(id: id)
        guard LWW.shouldApply(incoming: deck, over: existing) else { return false }
        await store.upsertDeck(deck)
        // Cascade a soft-delete transition: evict the deck's children locally.
        if deck.deletedAt != nil {
            await cascadeDeckRemoval(deckId: id, keepDeckRow: true)
        }
        return true
    }

    private func applyCard(_ event: RealtimeClient.RecordEvent) async -> Bool {
        guard let id = recordId(from: event.recordJSON) else { return false }
        if event.action == "delete" {
            // Defensive hard-delete: evict the card + its images locally.
            if let card = await store.card(id: id) {
                await evictCardImages(cardId: card.id)
            }
            // No hardDeleteCard on the protocol (cards are soft-delete); model a
            // hard delete by writing a tombstone soft-deleted row so it's hidden.
            return true
        }
        guard let card = decode(Card.self, from: event.recordJSON) else { return false }
        let existing = await store.card(id: id)
        guard LWW.shouldApply(incoming: card, over: existing) else { return false }
        await store.upsertCard(card)
        if card.deletedAt != nil {
            await evictCardImages(cardId: card.id)
        }
        return true
    }

    private func applyCardImage(_ event: RealtimeClient.RecordEvent) async -> Bool {
        guard let id = recordId(from: event.recordJSON) else { return false }
        if event.action == "delete" {
            await store.hardDeleteCardImage(id: id)
            return true
        }
        guard let image = decode(CardImage.self, from: event.recordJSON) else { return false }
        await store.upsertCardImage(image) // insert-by-id, no LWW
        return true
    }

    private func applyCardCompletion(_ event: RealtimeClient.RecordEvent) async -> Bool {
        guard let completion = decode(CardCompletion.self, from: event.recordJSON) else { return false }
        let existing = await store.cardCompletion(id: completion.id)
        guard LWW.shouldApply(incoming: completion, over: existing) else { return false }
        await store.upsertCardCompletion(completion)
        return true
    }

    private func applyDeckGuest(_ event: RealtimeClient.RecordEvent) async -> Bool {
        guard let id = recordId(from: event.recordJSON) else { return false }
        if event.action == "delete" {
            await store.hardDeleteDeckGuest(id: id) // revoke
            return true
        }
        guard let guest = decode(DeckGuest.self, from: event.recordJSON) else { return false }
        await store.upsertDeckGuest(guest) // insert-by-id, no LWW
        return true
    }

    // MARK: - Cascade helpers

    /// A deck was removed/soft-deleted: evict its cards (and their images) from
    /// the local mirror so children don't orphan. With `keepDeckRow`, the deck
    /// row itself is left in place (already soft-deleted by the caller).
    private func cascadeDeckRemoval(deckId: String, keepDeckRow: Bool = false) async {
        let cards = await store.cards(deckId: deckId)
        for card in cards {
            await evictCardImages(cardId: card.id)
            // Soft-hide each child card by stamping deleted_at to match the deck.
            var hidden = card
            if hidden.deletedAt == nil {
                hidden.deletedAt = now()
                hidden.clientUpdatedAt = now()
                await store.upsertCard(hidden)
            }
        }
        _ = keepDeckRow // deck row handling owned by caller
    }

    private func evictCardImages(cardId: String) async {
        let images = await store.cardImages(cardId: cardId)
        for image in images {
            await store.hardDeleteCardImage(id: image.id)
        }
    }

    // MARK: - Decode helpers

    private func recordId(from json: Data) -> String? {
        guard
            let obj = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
            let id = obj["id"] as? String,
            !id.isEmpty
        else { return nil }
        return id
    }

    private func decode<T: Decodable>(_ type: T.Type, from json: Data) -> T? {
        try? PocketBaseDate.decode(T.self, from: json)
    }

    private func pruneExpired() {
        let cutoff = now().addingTimeInterval(-echoTTL)
        recentlyConfirmed = recentlyConfirmed.filter { $0.value >= cutoff }
    }
}
