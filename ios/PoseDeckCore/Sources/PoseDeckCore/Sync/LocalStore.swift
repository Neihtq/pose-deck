import Foundation

/// A record that the sync layer can merge last-write-wins (LWW).
///
/// The ordering key is **per-conformance**, not uniform (M3 plan, invariant
/// #3): the locked PocketBase model does not give every collection a
/// `client_updated_at`, so a single hard-coded key would be a lie for images
/// and guests.
///
///  - `Deck`, `Card` → `clientUpdatedAt`
///  - `CardCompletion` → `changedAt`
///  - `CardImage`, `DeckGuest` → `nil` (no LWW): create is insert-by-id, delete
///    is a hard remove-by-id, and an echo lacking bytes must never overwrite a
///    present local row.
///
/// A `nil` `orderingTimestamp` means "always apply" for create/insert and "hard
/// remove" for delete — see ``LWW`` and ``SyncEngine``.
public protocol SyncRecord: Identifiable, Sendable where ID == String {
    /// The LWW ordering timestamp for this record, or `nil` when the collection
    /// has no LWW clock (images/guests).
    var orderingTimestamp: Date? { get }
}

extension Deck: SyncRecord {
    public var orderingTimestamp: Date? { clientUpdatedAt }
}

extension Card: SyncRecord {
    public var orderingTimestamp: Date? { clientUpdatedAt }
}

extension CardCompletion: SyncRecord {
    public var orderingTimestamp: Date? { changedAt }
}

extension CardImage: SyncRecord {
    /// No LWW clock — create is insert-by-id, delete is hard remove-by-id.
    public var orderingTimestamp: Date? { nil }
}

extension DeckGuest: SyncRecord {
    /// No LWW clock — insert on grant, hard remove on revoke.
    public var orderingTimestamp: Date? { nil }
}

/// Pure last-write-wins decision, shared by the offline write path, the realtime
/// merge, and any reconciling resync so they can never diverge (M3 plan,
/// invariant #3).
public enum LWW {

    /// Whether an `incoming` record should overwrite the `existing` local one.
    ///
    /// Semantics:
    ///  - No existing row → always apply (it's an insert).
    ///  - Either side has a `nil` ordering clock (images/guests, or a
    ///    server row that never carried `client_updated_at`) → apply: there is
    ///    no clock to lose by, and the incoming value is the freshest known
    ///    server/echo state. (Self-echo of our *own* in-flight writes is handled
    ///    separately by the recently-confirmed set, invariant #4, so this does
    ///    not clobber pending local edits.)
    ///  - Both clocks present → apply iff incoming is **strictly newer**. A tie
    ///    is skipped (don't churn on equal clocks).
    public static func shouldApply<R: SyncRecord>(incoming: R, over existing: R?) -> Bool {
        guard let existing else { return true }
        guard let lhs = incoming.orderingTimestamp, let rhs = existing.orderingTimestamp else {
            return true
        }
        return lhs > rhs
    }
}

/// Abstraction over the local mirror of the five synced collections
/// (ARCHITECTURE.md §4.1). The production app backs this with SwiftData; tests,
/// previews, and the core engine use ``InMemoryLocalStore``.
///
/// Writes go through ``upsert(_:)`` (LWW) / ``hardDelete(_:id:)`` so the merge
/// rule is centralized. Reads are simple id/relation lookups; richer querying is
/// the app layer's concern.
public protocol LocalStore: Sendable {
    // Decks
    func upsertDeck(_ deck: Deck) async
    func deck(id: String) async -> Deck?
    func allDecks() async -> [Deck]
    /// Local-only display hide for a deck, used when a realtime hard-`delete`
    /// event arrives for a deck (defensive — the server uses soft-delete, but a
    /// hard delete event must still evict the deck locally; module doc §contract).
    ///
    /// Sets the deck's `deletedAt` so the `listDecks` filter hides it, but **must
    /// not** change `clientUpdatedAt`: the LWW clock belongs to the real server
    /// row. Stamping a fresh clock here would shadow a genuine server row that
    /// later re-delivers with its older-but-true timestamp. This write therefore
    /// bypasses LWW entirely — same contract as ``hideCard(id:deletedAt:)``.
    func hideDeck(id: String, deletedAt: Date) async

    // Cards
    func upsertCard(_ card: Card) async
    func card(id: String) async -> Card?
    func cards(deckId: String) async -> [Card]
    /// Local-only display hide for a cascaded child of a soft-deleted deck.
    ///
    /// Sets the card's `deletedAt` so the parent-deck filter hides it, but
    /// **must not** change `clientUpdatedAt`: the LWW clock belongs to the real
    /// server row. Stamping a fresh clock here would permanently shadow the
    /// genuine server card after a deck restore (the older-but-true row would
    /// lose LWW against the fabricated future timestamp). This write therefore
    /// bypasses LWW entirely — it is a local view concern, not a merge.
    func hideCard(id: String, deletedAt: Date) async
    /// Local-only display un-hide: clear a card's `deletedAt` while preserving
    /// `clientUpdatedAt`, bypassing LWW. The mirror image of ``hideCard`` — used
    /// when a soft-deleted deck is restored so its cascaded children return to
    /// live without depending on the server re-delivering each card (the server
    /// never soft-deleted them, so it would never re-deliver them with a fresh
    /// clock that could overturn the local hidden row).
    func unhideCard(id: String) async

    // Card images (no LWW; hard delete)
    func upsertCardImage(_ image: CardImage) async
    func cardImage(id: String) async -> CardImage?
    func cardImages(cardId: String) async -> [CardImage]
    func hardDeleteCardImage(id: String) async

    // Card completions
    func upsertCardCompletion(_ completion: CardCompletion) async
    func cardCompletion(id: String) async -> CardCompletion?
    /// Force-apply a user-originated completion, **bypassing the LWW tie guard**
    /// (`[FIX-M1]`).
    ///
    /// The optimistic local write for a user's own shoot action must always take
    /// effect — even when `changedAt` exactly equals the existing row's clock
    /// (e.g. `markDone → clear → markDone` under a constant injected clock). The
    /// shared ``LWW`` rule *skips* such ties, so routing the user's own action
    /// through ``upsertCardCompletion(_:)`` would make it a silent no-op. This
    /// seam unconditionally writes the user action; ``upsertCardCompletion(_:)``
    /// (LWW) stays the path for *incoming* realtime echoes so an out-of-order
    /// echo still cannot clobber a newer local row.
    func applyLocalCardCompletion(_ completion: CardCompletion) async
    /// All completions whose `card` is in `cardIds` (the deck-scoped read —
    /// completions hold no deck relation, so the deck scope is expressed via its
    /// card ids).
    func cardCompletions(cardIds: [String]) async -> [CardCompletion]

    // Deck guests (no LWW; hard delete on revoke)
    func upsertDeckGuest(_ guest: DeckGuest) async
    func deckGuest(id: String) async -> DeckGuest?
    func deckGuests(deckId: String) async -> [DeckGuest]
    /// All mirrored deck-guest rows (used by the backfill reconcile-prune to find
    /// mirror rows no longer present on the server).
    func allDeckGuests() async -> [DeckGuest]
    func hardDeleteDeckGuest(id: String) async
}

/// In-memory ``LocalStore`` for tests, previews, and the engine's default path.
///
/// All mutating writes apply the shared ``LWW`` rule so an out-of-order realtime
/// echo cannot clobber a newer local row. Thread-safe via actor isolation.
public actor InMemoryLocalStore: LocalStore {
    private var decks: [String: Deck] = [:]
    private var cards: [String: Card] = [:]
    private var cardImages: [String: CardImage] = [:]
    private var cardCompletions: [String: CardCompletion] = [:]
    private var deckGuests: [String: DeckGuest] = [:]

    public init() {}

    // MARK: Decks

    public func upsertDeck(_ deck: Deck) async {
        if LWW.shouldApply(incoming: deck, over: decks[deck.id]) {
            decks[deck.id] = deck
        }
    }

    public func deck(id: String) async -> Deck? { decks[id] }

    public func allDecks() async -> [Deck] { Array(decks.values) }

    public func hideDeck(id: String, deletedAt: Date) async {
        // Local-only display hide: set deleted_at but preserve client_updated_at
        // and bypass LWW (mirror of hideCard) — a hard-delete event evicts the
        // deck from the listing without poisoning the merge clock.
        guard var deck = decks[id] else { return }
        deck.deletedAt = deletedAt
        decks[id] = deck
    }

    // MARK: Cards

    public func upsertCard(_ card: Card) async {
        if LWW.shouldApply(incoming: card, over: cards[card.id]) {
            cards[card.id] = card
        }
    }

    public func card(id: String) async -> Card? { cards[id] }

    public func hideCard(id: String, deletedAt: Date) async {
        // Local-only display hide: set deleted_at but preserve client_updated_at
        // and bypass LWW so the cascade can never poison the merge clock.
        guard var card = cards[id] else { return }
        card.deletedAt = deletedAt
        cards[id] = card
    }

    public func unhideCard(id: String) async {
        // Local-only display un-hide: clear deleted_at, preserve client_updated_at,
        // bypass LWW (mirror of hideCard).
        guard var card = cards[id] else { return }
        card.deletedAt = nil
        cards[id] = card
    }

    public func cards(deckId: String) async -> [Card] {
        cards.values.filter { $0.deck == deckId }.sorted { $0.position < $1.position }
    }

    // MARK: Card images (insert-by-id / hard-delete, no LWW)

    public func upsertCardImage(_ image: CardImage) async {
        // No LWW: an existing local row already has the freshest bytes/filename
        // we know about, so a present row wins over a re-inserting echo. Only
        // insert when absent.
        if cardImages[image.id] == nil {
            cardImages[image.id] = image
        }
    }

    public func cardImage(id: String) async -> CardImage? { cardImages[id] }

    public func cardImages(cardId: String) async -> [CardImage] {
        cardImages.values.filter { $0.card == cardId }.sorted { $0.position < $1.position }
    }

    public func hardDeleteCardImage(id: String) async {
        cardImages[id] = nil
    }

    // MARK: Card completions

    public func upsertCardCompletion(_ completion: CardCompletion) async {
        if LWW.shouldApply(incoming: completion, over: cardCompletions[completion.id]) {
            cardCompletions[completion.id] = completion
        }
    }

    public func cardCompletion(id: String) async -> CardCompletion? { cardCompletions[id] }

    public func applyLocalCardCompletion(_ completion: CardCompletion) async {
        // `[FIX-M1]`: a user's own action always wins locally — bypass the LWW
        // tie guard so an equal-clock re-mark is never a silent no-op.
        cardCompletions[completion.id] = completion
    }

    public func cardCompletions(cardIds: [String]) async -> [CardCompletion] {
        let wanted = Set(cardIds)
        return cardCompletions.values.filter { wanted.contains($0.card) }
    }

    // MARK: Deck guests (insert / hard-delete on revoke, no LWW)

    public func upsertDeckGuest(_ guest: DeckGuest) async {
        if deckGuests[guest.id] == nil {
            deckGuests[guest.id] = guest
        }
    }

    public func deckGuest(id: String) async -> DeckGuest? { deckGuests[id] }

    public func deckGuests(deckId: String) async -> [DeckGuest] {
        deckGuests.values.filter { $0.deck == deckId }.sorted {
            ($0.grantedAt ?? .distantPast) < ($1.grantedAt ?? .distantPast)
        }
    }

    public func allDeckGuests() async -> [DeckGuest] { Array(deckGuests.values) }

    public func hardDeleteDeckGuest(id: String) async {
        deckGuests[id] = nil
    }
}
