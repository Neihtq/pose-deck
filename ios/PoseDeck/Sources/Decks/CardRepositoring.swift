import Foundation
import PoseDeckCore

/// App-side abstraction over ``CardRepository`` (mirrors ``DeckRepositoring``)
/// so the deck-detail screen can be driven by a fake in previews/tests.
@MainActor
protocol CardRepositoring {
    func listCards(deckId: String) async throws -> [Card]
    @discardableResult
    func createCard(deckId: String, fields: CardRepository.CardFields) async throws -> Card
    @discardableResult
    func updateCard(id: String, fields: CardRepository.PartialCardFields) async throws -> Card
    @discardableResult
    func softDeleteCard(id: String) async throws -> Card
    func reorderCards(deckId: String, orderedIds: [String], currentPositions: [String: Int]?) async throws
}

extension CardRepository: CardRepositoring {}

/// App-side abstraction over the image repository, scoped to what the
/// deck-detail thumbnail strip needs (first image per card).
@MainActor
protocol CardImageReading {
    func listCardImages(cardId: String) async throws -> [CardImage]
    func fileURL(for image: CardImage) async throws -> URL
}

extension ImageRepository: CardImageReading {}
