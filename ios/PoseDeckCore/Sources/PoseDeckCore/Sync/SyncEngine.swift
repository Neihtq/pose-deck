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
            // Defensive hard-delete: hide the deck row + cascade to its children.
            // Decks are soft-delete (no hardDeleteDeck on the protocol), so model a
            // hard delete with a display tombstone via hideDeck — it stamps
            // deleted_at (so listDecks excludes it) while preserving
            // client_updated_at, never poisoning the LWW clock (same contract as
            // the child cascade). If the row is unknown locally there is nothing
            // visible to hide, but a cascade is still safe (no-op on no children).
            let stamp = now()
            if let deck = await store.deck(id: id), deck.deletedAt == nil {
                await store.hideDeck(id: id, deletedAt: stamp)
            }
            await cascadeDeckRemoval(deckId: id, hideAt: stamp)
            return true
        }
        guard let deck = decode(Deck.self, from: event.recordJSON) else { return false }
        let existing = await store.deck(id: id)
        guard LWW.shouldApply(incoming: deck, over: existing) else { return false }
        let previousDeletedAt = existing?.deletedAt
        await store.upsertDeck(deck)
        if let deckDeletedAt = deck.deletedAt {
            // Cascade a soft-delete transition: hide the deck's children locally,
            // stamping each child's deleted_at to the deck's own deleted_at.
            await cascadeDeckRemoval(deckId: id, keepDeckRow: true, hideAt: deckDeletedAt)
        } else if let previousDeletedAt {
            // Cascade a restore transition: un-hide ONLY children this cascade hid
            // (deleted_at == the deck's prior deleted_at), so a card the user
            // individually trashed stays trashed. The server never soft-deleted
            // the cards (web parity: restoreDeck clears only the deck row), so
            // nothing else re-delivers them; the LWW clock was preserved, so this
            // pure display un-hide is safe.
            await cascadeDeckRestore(deckId: id, hiddenAt: previousDeletedAt)
        }
        return true
    }

    private func applyCard(_ event: RealtimeClient.RecordEvent) async -> Bool {
        guard let id = recordId(from: event.recordJSON) else { return false }
        if event.action == "delete" {
            // Defensive hard-delete: evict the card + its images locally and hide
            // the card row. Cards are soft-delete (no hardDeleteCard on the
            // protocol), so model a hard delete with a display tombstone via
            // hideCard — it stamps deleted_at (so listCards excludes it) while
            // preserving client_updated_at, never poisoning the LWW clock (same
            // contract as the deck cascade). If the row is unknown locally there is
            // nothing visible to hide, so report no change.
            guard let card = await store.card(id: id) else { return false }
            await evictCardImages(cardId: card.id)
            if card.deletedAt == nil {
                await store.hideCard(id: card.id, deletedAt: now())
            }
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
    ///
    /// `hideAt` is the timestamp stamped into each child card's `deleted_at` to
    /// hide it for display. It defaults to `now()` for a hard-delete event (no
    /// deck row to derive from) and is otherwise the deck's own `deleted_at`.
    /// Crucially, hiding goes through ``LocalStore/hideCard(id:deletedAt:)`` so
    /// the child's `client_updated_at` (its real LWW clock) is left untouched —
    /// the server never soft-deletes cards on a deck delete (web parity:
    /// `deckApi.softDeleteDeck` patches only the deck row), so fabricating a
    /// fresh clock here would permanently shadow the genuine server card after a
    /// deck restore re-applies it with its older-but-true timestamp.
    private func cascadeDeckRemoval(deckId: String, keepDeckRow: Bool = false, hideAt: Date? = nil) async {
        let hideStamp = hideAt ?? now()
        let cards = await store.cards(deckId: deckId)
        for card in cards {
            await evictCardImages(cardId: card.id)
            if card.deletedAt == nil {
                await store.hideCard(id: card.id, deletedAt: hideStamp)
            }
        }
        _ = keepDeckRow // deck row handling owned by caller
    }

    /// A soft-deleted deck was restored: un-hide the children the cascade hid.
    /// Pairs with ``cascadeDeckRemoval`` — both touch only `deleted_at` for
    /// display and never the LWW clock, so a restore cleanly reverses a delete.
    ///
    /// `hiddenAt` is the deck's prior `deleted_at` (the exact value the cascade
    /// stamped into each child). Only children carrying that stamp are un-hidden,
    /// so a card the user individually soft-deleted (a different `deleted_at`)
    /// stays trashed.
    private func cascadeDeckRestore(deckId: String, hiddenAt: Date) async {
        let cards = await store.cards(deckId: deckId)
        // Shared predicate (also used by the app's optimistic restore path) so the
        // two can never diverge: un-hide only children carrying the deck's prior
        // deleted_at; an individually-trashed card stays trashed.
        for id in DeckCascade.childIdsToUnhideOnRestore(cards: cards, hiddenAt: hiddenAt) {
            await store.unhideCard(id: id)
        }
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
