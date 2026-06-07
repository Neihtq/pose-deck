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
///
/// `Sendable` so `DeckDetailViewModel.loadThumbnails()` can capture it in the
/// `@Sendable` per-card closure handed to `ThumbnailResolver` (the concurrent
/// fan-out that replaced the serialized per-card network loop —
/// `swift-mirror-image-network-per-read`). All conformers are `@MainActor`
/// (`MirrorImageRepository`, `ImageRepository`, the preview fake), so they are
/// already implicitly `Sendable`; the closure's `@MainActor` calls hop back to
/// the main actor.
@MainActor
protocol CardImageReading: Sendable {
    func listCardImages(cardId: String) async throws -> [CardImage]
    func fileURL(for image: CardImage) async throws -> URL
}

extension ImageRepository: CardImageReading {}
