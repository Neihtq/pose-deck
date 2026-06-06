import Foundation
import PoseDeckCore

/// In-memory ``DeckRepositoring`` for `#Preview`s. Not used in production.
@MainActor
final class FakeDeckRepository: DeckRepositoring {
    var decks: [Deck]
    var trashed: [Deck]
    /// When non-nil, every method throws this (to preview error states).
    var error: Error?

    init(decks: [Deck] = FakeDeckRepository.sample, trashed: [Deck] = [], error: Error? = nil) {
        self.decks = decks
        self.trashed = trashed
        self.error = error
    }

    private func check() throws { if let error { throw error } }

    func listDecks() async throws -> [Deck] { try check(); return decks }

    func getDeck(id: String) async throws -> Deck {
        try check()
        guard let deck = decks.first(where: { $0.id == id }) else {
            throw DeckRepositoryError.notFound(id: id)
        }
        return deck
    }

    func listTrashedDecks() async throws -> [Deck] { try check(); return trashed }

    @discardableResult
    func createDeck(name: String, shootDate: Date?, ownerId: String) async throws -> Deck {
        try check()
        let deck = Deck(id: UUID().uuidString, owner: ownerId, name: name, shootDate: shootDate)
        decks.append(deck)
        return deck
    }

    @discardableResult
    func renameDeck(id: String, name: String) async throws -> Deck {
        try check()
        guard let idx = decks.firstIndex(where: { $0.id == id }) else {
            throw DeckRepositoryError.notFound(id: id)
        }
        decks[idx].name = name
        return decks[idx]
    }

    @discardableResult
    func setShootDate(id: String, shootDate: Date?) async throws -> Deck {
        try check()
        guard let idx = decks.firstIndex(where: { $0.id == id }) else {
            throw DeckRepositoryError.notFound(id: id)
        }
        decks[idx].shootDate = shootDate
        return decks[idx]
    }

    @discardableResult
    func softDeleteDeck(id: String) async throws -> Deck {
        try check()
        guard let idx = decks.firstIndex(where: { $0.id == id }) else {
            throw DeckRepositoryError.notFound(id: id)
        }
        var deck = decks.remove(at: idx)
        deck.deletedAt = Date()
        trashed.insert(deck, at: 0)
        return deck
    }

    @discardableResult
    func restoreDeck(id: String) async throws -> Deck {
        try check()
        guard let idx = trashed.firstIndex(where: { $0.id == id }) else {
            throw DeckRepositoryError.notFound(id: id)
        }
        var deck = trashed.remove(at: idx)
        deck.deletedAt = nil
        decks.append(deck)
        return deck
    }

    @discardableResult
    func duplicateDeck(id: String, ownerId: String) async throws -> Deck {
        try check()
        let source = try await getDeck(id: id)
        let copy = Deck(id: UUID().uuidString, owner: ownerId, name: "\(source.name) (copy)")
        decks.append(copy)
        return copy
    }

    /// A spread of decks across all three groups for previews.
    nonisolated static var sample: [Deck] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return [
            Deck(id: "d1", owner: "u1", name: "Smith Wedding",
                 shootDate: cal.date(byAdding: .day, value: 7, to: today)),
            Deck(id: "d2", owner: "u1", name: "Brand Lookbook",
                 shootDate: cal.date(byAdding: .day, value: 1, to: today)),
            Deck(id: "d3", owner: "u1", name: "Studio Ideas", shootDate: nil),
            Deck(id: "d4", owner: "u1", name: "Maternity Session",
                 shootDate: cal.date(byAdding: .day, value: -14, to: today)),
            Deck(id: "d5", owner: "u1", name: "Autumn Portraits",
                 shootDate: cal.date(byAdding: .day, value: -3, to: today)),
        ]
    }
}

/// In-memory ``CardRepositoring`` for `#Preview`s.
@MainActor
final class FakeCardRepository: CardRepositoring {
    var cardsByDeck: [String: [Card]]
    var error: Error?

    init(cardsByDeck: [String: [Card]] = FakeCardRepository.sample, error: Error? = nil) {
        self.cardsByDeck = cardsByDeck
        self.error = error
    }

    private func check() throws { if let error { throw error } }

    func listCards(deckId: String) async throws -> [Card] {
        try check()
        return (cardsByDeck[deckId] ?? []).sorted { $0.position < $1.position }
    }

    @discardableResult
    func createCard(deckId: String, fields: CardRepository.CardFields) async throws -> Card {
        try check()
        var list = cardsByDeck[deckId] ?? []
        let position = CardRepository.nextPosition(after: list)
        let card = Card(id: UUID().uuidString, deck: deckId, position: position,
                        title: String(fields.title.prefix(CardRepository.titleMaxLength)),
                        timeSlot: fields.timeSlot, subjects: fields.subjects,
                        direction: fields.direction, notes: fields.notes)
        list.append(card)
        cardsByDeck[deckId] = list
        return card
    }

    @discardableResult
    func updateCard(id: String, fields: CardRepository.PartialCardFields) async throws -> Card {
        try check()
        for (deck, var list) in cardsByDeck {
            if let idx = list.firstIndex(where: { $0.id == id }) {
                if let t = fields.title { list[idx].title = String(t.prefix(CardRepository.titleMaxLength)) }
                if let v = fields.timeSlot { list[idx].timeSlot = v }
                if let v = fields.subjects { list[idx].subjects = v }
                if let v = fields.direction { list[idx].direction = v }
                if let v = fields.notes { list[idx].notes = v }
                cardsByDeck[deck] = list
                return list[idx]
            }
        }
        throw DeckRepositoryError.notFound(id: id)
    }

    @discardableResult
    func softDeleteCard(id: String) async throws -> Card {
        try check()
        for (deck, var list) in cardsByDeck {
            if let idx = list.firstIndex(where: { $0.id == id }) {
                let card = list.remove(at: idx)
                cardsByDeck[deck] = list
                return card
            }
        }
        throw DeckRepositoryError.notFound(id: id)
    }

    func reorderCards(deckId: String, orderedIds: [String], currentPositions: [String: Int]?) async throws {
        try check()
        guard var list = cardsByDeck[deckId] else { return }
        for (id, position) in CardRepository.computeReorderedPositions(orderedIds: orderedIds) {
            if let idx = list.firstIndex(where: { $0.id == id }) {
                list[idx].position = position
            }
        }
        cardsByDeck[deckId] = list
    }

    nonisolated static var sample: [String: [Card]] {
        [
            "d1": [
                Card(id: "c1", deck: "d1", position: 1000, title: "Getting ready",
                     timeSlot: "9:00 AM", subjects: "Bride"),
                Card(id: "c2", deck: "d1", position: 2000, title: "First look",
                     timeSlot: "11:00 AM", subjects: "Bride & Groom",
                     direction: "Soft window light"),
                Card(id: "c3", deck: "d1", position: 3000, title: "Family formals",
                     subjects: "Full family"),
            ],
        ]
    }
}

/// A ``CardImageReading`` that returns no images — keeps deck-detail previews
/// offline (no network token mint, no remote fetch).
@MainActor
final class FakeCardImageRepository: CardImageReading {
    var imagesByCard: [String: [CardImage]]
    init(imagesByCard: [String: [CardImage]] = [:]) { self.imagesByCard = imagesByCard }
    func listCardImages(cardId: String) async throws -> [CardImage] { imagesByCard[cardId] ?? [] }
    func fileURL(for image: CardImage) async throws -> URL {
        URL(string: "https://example.invalid/\(image.id)")!
    }
}
