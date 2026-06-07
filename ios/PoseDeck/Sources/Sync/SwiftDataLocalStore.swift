import Foundation
import SwiftData
import PoseDeckCore

/// SwiftData-backed conformance to the PoseDeckCore ``LocalStore`` protocol
/// (M3 plan, STEP 10).
///
/// This is the bridge that lets the shared ``OfflineWritePath`` (optimistic
/// local writes) and ``SyncEngine`` (realtime LWW merge) operate on the *same*
/// persisted SwiftData mirror the views read from — so an optimistic write and a
/// realtime echo land in one store and the UI sees a single coherent state.
///
/// All access runs on a dedicated background `ModelContext` owned by this actor
/// (SwiftData contexts are not `Sendable`; the context never escapes the actor).
/// Writes apply the shared ``LWW`` rule (via ``MirrorMerge``) so an out-of-order
/// echo cannot clobber a newer local row; images/guests insert-by-id / hard
/// delete with no clock (invariant #3).
actor SwiftDataLocalStore: LocalStore {

    private let context: ModelContext

    init(container: ModelContainer) {
        self.context = ModelContext(container)
    }

    // MARK: - Decks

    func upsertDeck(_ deck: Deck) async {
        let id = deck.id
        let existing = try? context.fetch(
            FetchDescriptor<LocalDeck>(predicate: #Predicate { $0.id == id })
        ).first
        guard MirrorMerge.shouldApply(incoming: deck.clientUpdatedAt, existing: existing?.clientUpdatedAt) else {
            return
        }
        if let existing {
            existing.apply(deck)
        } else {
            context.insert(LocalDeck(
                id: deck.id, owner: deck.owner, name: deck.name, shootDate: deck.shootDate,
                clientUpdatedAt: deck.clientUpdatedAt, created: deck.created,
                updated: deck.updated, deletedAt: deck.deletedAt
            ))
        }
        try? context.save()
    }

    func deck(id: String) async -> Deck? {
        (try? context.fetch(FetchDescriptor<LocalDeck>(predicate: #Predicate { $0.id == id })).first)?.asDeck
    }

    func allDecks() async -> [Deck] {
        ((try? context.fetch(FetchDescriptor<LocalDeck>())) ?? []).map(\.asDeck)
    }

    func hideDeck(id: String, deletedAt: Date) async {
        // Local-only display hide for a hard-delete event: set deleted_at but
        // leave client_updated_at (the real LWW clock) untouched and bypass LWW,
        // so a genuine server row that later re-delivers with its true timestamp
        // is not shadowed. Mirror of hideCard.
        guard let existing = try? context.fetch(
            FetchDescriptor<LocalDeck>(predicate: #Predicate { $0.id == id })
        ).first else { return }
        existing.deletedAt = deletedAt
        try? context.save()
    }

    // MARK: - Cards

    func upsertCard(_ card: Card) async {
        let id = card.id
        let existing = try? context.fetch(
            FetchDescriptor<LocalCard>(predicate: #Predicate { $0.id == id })
        ).first
        guard MirrorMerge.shouldApply(incoming: card.clientUpdatedAt, existing: existing?.clientUpdatedAt) else {
            return
        }
        if let existing {
            existing.apply(card)
        } else {
            context.insert(LocalCard(
                id: card.id, deck: card.deck, position: card.position, title: card.title,
                timeSlot: card.timeSlot, subjects: card.subjects, direction: card.direction,
                notes: card.notes, clientUpdatedAt: card.clientUpdatedAt, created: card.created,
                updated: card.updated, deletedAt: card.deletedAt
            ))
        }
        try? context.save()
    }

    func card(id: String) async -> Card? {
        (try? context.fetch(FetchDescriptor<LocalCard>(predicate: #Predicate { $0.id == id })).first)?.asCard
    }

    func hideCard(id: String, deletedAt: Date) async {
        // Local-only display hide for a cascaded child: set deleted_at but leave
        // client_updated_at (the real LWW clock) untouched and bypass LWW, so a
        // later deck restore that re-applies the genuine server card un-hides it.
        guard let existing = try? context.fetch(
            FetchDescriptor<LocalCard>(predicate: #Predicate { $0.id == id })
        ).first else { return }
        existing.deletedAt = deletedAt
        try? context.save()
    }

    func unhideCard(id: String) async {
        // Local-only display un-hide (mirror of hideCard): clear deleted_at,
        // preserve client_updated_at, bypass LWW.
        guard let existing = try? context.fetch(
            FetchDescriptor<LocalCard>(predicate: #Predicate { $0.id == id })
        ).first else { return }
        existing.deletedAt = nil
        try? context.save()
    }

    func restoreCard(_ card: Card) async {
        // [CORR-2] LWW-bypassing rollback for a failed reorder: re-apply the
        // captured pre-reorder snapshot (position + original client_updated_at)
        // verbatim. A plain upsertCard would lose LWW because the in-store row
        // already carries the fresher reorder clock. No-op if the row is absent.
        let id = card.id
        guard let existing = try? context.fetch(
            FetchDescriptor<LocalCard>(predicate: #Predicate { $0.id == id })
        ).first else { return }
        existing.apply(card)
        try? context.save()
    }

    func cards(deckId: String) async -> [Card] {
        let descriptor = FetchDescriptor<LocalCard>(
            predicate: #Predicate { $0.deck == deckId },
            sortBy: [SortDescriptor(\.position, order: .forward)]
        )
        return ((try? context.fetch(descriptor)) ?? []).map(\.asCard)
    }

    // MARK: - Card images (no LWW: insert-by-id / hard delete)

    func upsertCardImage(_ image: CardImage) async {
        let id = image.id
        let existing = try? context.fetch(
            FetchDescriptor<LocalCardImage>(predicate: #Predicate { $0.id == id })
        ).first
        // No LWW: a present local row already holds the freshest bytes/filename
        // we know about, so only insert when absent (never overwrite a cached
        // blob with a bytes-less echo).
        guard existing == nil else { return }
        context.insert(LocalCardImage(
            id: image.id, card: image.card, position: image.position,
            file: image.file, created: image.created
        ))
        try? context.save()
    }

    func cardImage(id: String) async -> CardImage? {
        (try? context.fetch(FetchDescriptor<LocalCardImage>(predicate: #Predicate { $0.id == id })).first)?.asCardImage
    }

    func cardImages(cardId: String) async -> [CardImage] {
        let descriptor = FetchDescriptor<LocalCardImage>(
            predicate: #Predicate { $0.card == cardId },
            sortBy: [SortDescriptor(\.position, order: .forward)]
        )
        return ((try? context.fetch(descriptor)) ?? []).map(\.asCardImage)
    }

    func hardDeleteCardImage(id: String) async {
        let descriptor = FetchDescriptor<LocalCardImage>(predicate: #Predicate { $0.id == id })
        if let row = try? context.fetch(descriptor).first {
            context.delete(row)
            try? context.save()
        }
    }

    // MARK: - Card completions

    func upsertCardCompletion(_ completion: CardCompletion) async {
        let id = completion.id
        let existing = try? context.fetch(
            FetchDescriptor<LocalCardCompletion>(predicate: #Predicate { $0.id == id })
        ).first
        guard MirrorMerge.shouldApply(incoming: completion.changedAt, existing: existing?.changedAt) else {
            return
        }
        if let existing {
            existing.card = completion.card
            existing.user = completion.user
            existing.stateRaw = completion.state.rawValue
            existing.changedAt = completion.changedAt
        } else {
            context.insert(LocalCardCompletion(
                id: completion.id, card: completion.card, user: completion.user,
                stateRaw: completion.state.rawValue, changedAt: completion.changedAt
            ))
        }
        try? context.save()
    }

    func cardCompletion(id: String) async -> CardCompletion? {
        guard let row = try? context.fetch(
            FetchDescriptor<LocalCardCompletion>(predicate: #Predicate { $0.id == id })
        ).first else { return nil }
        return row.asCardCompletion
    }

    /// `[FIX-M1]`: force-apply a user-originated completion, **bypassing the LWW
    /// tie guard**. Unlike ``upsertCardCompletion(_:)`` (which routes through
    /// ``MirrorMerge``/LWW for incoming realtime echoes), the user's own shoot
    /// action must always take effect locally — even when `changedAt` equals the
    /// existing row's clock (e.g. markDone → clear → markDone under a constant
    /// injected clock).
    func applyLocalCardCompletion(_ completion: CardCompletion) async {
        let id = completion.id
        let existing = try? context.fetch(
            FetchDescriptor<LocalCardCompletion>(predicate: #Predicate { $0.id == id })
        ).first
        if let existing {
            existing.card = completion.card
            existing.user = completion.user
            existing.stateRaw = completion.state.rawValue
            existing.changedAt = completion.changedAt
        } else {
            context.insert(LocalCardCompletion(
                id: completion.id, card: completion.card, user: completion.user,
                stateRaw: completion.state.rawValue, changedAt: completion.changedAt
            ))
        }
        try? context.save()
    }

    /// Deck-scoped completion read (`[B1]`): completions hold no deck relation, so
    /// the deck scope is expressed via its card ids.
    func cardCompletions(cardIds: [String]) async -> [CardCompletion] {
        guard !cardIds.isEmpty else { return [] }
        let wanted = Set(cardIds)
        let descriptor = FetchDescriptor<LocalCardCompletion>(
            predicate: #Predicate { wanted.contains($0.card) }
        )
        return ((try? context.fetch(descriptor)) ?? []).map(\.asCardCompletion)
    }

    // MARK: - Deck guests (no LWW: insert / hard delete on revoke)

    func upsertDeckGuest(_ guest: DeckGuest) async {
        let id = guest.id
        let existing = try? context.fetch(
            FetchDescriptor<LocalDeckGuest>(predicate: #Predicate { $0.id == id })
        ).first
        guard existing == nil else { return }
        context.insert(LocalDeckGuest(id: guest.id, deck: guest.deck, user: guest.user, grantedAt: guest.grantedAt))
        try? context.save()
    }

    func deckGuest(id: String) async -> DeckGuest? {
        guard let row = try? context.fetch(
            FetchDescriptor<LocalDeckGuest>(predicate: #Predicate { $0.id == id })
        ).first else { return nil }
        return DeckGuest(id: row.id, deck: row.deck, user: row.user, grantedAt: row.grantedAt)
    }

    func deckGuests(deckId: String) async -> [DeckGuest] {
        let descriptor = FetchDescriptor<LocalDeckGuest>(
            predicate: #Predicate { $0.deck == deckId }
        )
        let rows = ((try? context.fetch(descriptor)) ?? [])
            .sorted { ($0.grantedAt ?? .distantPast) < ($1.grantedAt ?? .distantPast) }
        return rows.map { DeckGuest(id: $0.id, deck: $0.deck, user: $0.user, grantedAt: $0.grantedAt) }
    }

    func allDeckGuests() async -> [DeckGuest] {
        ((try? context.fetch(FetchDescriptor<LocalDeckGuest>())) ?? [])
            .map { DeckGuest(id: $0.id, deck: $0.deck, user: $0.user, grantedAt: $0.grantedAt) }
    }

    func hardDeleteDeckGuest(id: String) async {
        let descriptor = FetchDescriptor<LocalDeckGuest>(predicate: #Predicate { $0.id == id })
        if let row = try? context.fetch(descriptor).first {
            context.delete(row)
            try? context.save()
        }
    }

    // MARK: - Local-only lookups (offline pin)

    /// Ids of decks the user pinned for offline. Used by the pre-cache planner.
    func pinnedDeckIds() async -> [String] {
        let descriptor = FetchDescriptor<LocalDeck>(predicate: #Predicate { $0.pinnedForOffline == true })
        return ((try? context.fetch(descriptor)) ?? []).map(\.id)
    }
}
