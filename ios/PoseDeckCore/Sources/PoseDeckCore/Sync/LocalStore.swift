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

    // Cards
    func upsertCard(_ card: Card) async
    func card(id: String) async -> Card?
    func cards(deckId: String) async -> [Card]

    // Card images (no LWW; hard delete)
    func upsertCardImage(_ image: CardImage) async
    func cardImage(id: String) async -> CardImage?
    func cardImages(cardId: String) async -> [CardImage]
    func hardDeleteCardImage(id: String) async

    // Card completions
    func upsertCardCompletion(_ completion: CardCompletion) async
    func cardCompletion(id: String) async -> CardCompletion?

    // Deck guests (no LWW; hard delete on revoke)
    func upsertDeckGuest(_ guest: DeckGuest) async
    func deckGuest(id: String) async -> DeckGuest?
    func deckGuests(deckId: String) async -> [DeckGuest]
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

    // MARK: Cards

    public func upsertCard(_ card: Card) async {
        if LWW.shouldApply(incoming: card, over: cards[card.id]) {
            cards[card.id] = card
        }
    }

    public func card(id: String) async -> Card? { cards[id] }

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

    public func hardDeleteDeckGuest(id: String) async {
        deckGuests[id] = nil
    }
}
