import Foundation
import SwiftData
import PoseDeckCore

/// Pulls decks + cards + image bytes into the offline mirror so a pinned or
/// soon-to-shoot deck renders with no network (M3 plan, STEP 10).
///
/// An `actor` so a foreground manual pre-cache and a background-task pre-cache
/// can't run the same deck twice concurrently. Honors a `deadline` and task
/// cancellation (the BGTask `expirationHandler` cancels the running `Task`), and
/// only stamps `precachedAt` on a deck after a **full** success — a partial /
/// cancelled pull leaves `precachedAt` nil so the next run retries.
actor PrecacheService {

    /// Errors surfaced by the pre-cache.
    enum PrecacheError: Error { case cancelled, deadlineExceeded }

    private let container: ModelContainer
    private let context: ModelContext
    private let deckRepo: DeckRepository
    private let cardRepo: CardRepository
    private let imageRepo: ImageRepository
    /// Downloads bytes for a resolved file URL. Injectable for tests.
    private let download: @Sendable (URL) async throws -> Data

    /// A dedicated, non-persisting session for protected `card_images` fetches.
    /// Holding it for the service's lifetime keeps the download closure backed by
    /// one session rather than spinning up a new one per image.
    private static let protectedSession = ProtectedImageSession.make()

    init(
        container: ModelContainer,
        deckRepo: DeckRepository,
        cardRepo: CardRepository,
        imageRepo: ImageRepository,
        // Default fetches protected token-bearing image URLs through a dedicated
        // ephemeral/no-cache session (SEC-IOS-B) so decrypted private bytes are
        // never written to the process-global `URLCache.shared` on-disk store —
        // never relying on a sign-out-time purge to avoid cross-user remanence.
        download: @escaping @Sendable (URL) async throws -> Data = { url in
            try await PrecacheService.protectedSession.data(from: url).0
        }
    ) {
        self.container = container
        self.context = ModelContext(container)
        self.deckRepo = deckRepo
        self.cardRepo = cardRepo
        self.imageRepo = imageRepo
        self.download = download
    }

    /// Pre-cache the given deck ids into the mirror by `deadline`.
    ///
    /// For each target: fetch the deck + its cards (via the network repos) into
    /// the mirror, then download every image's bytes into `LocalCardImage.blob`.
    /// Stops cleanly if cancelled or past `deadline`, leaving already-completed
    /// decks cached and unfinished ones un-stamped for the next run.
    ///
    /// - Returns: the deck ids that were fully pre-cached this run.
    @discardableResult
    func precache(targets: [String], deadline: Date) async -> [String] {
        var completed: [String] = []
        for deckId in targets {
            if Task.isCancelled || Date() >= deadline { break }
            do {
                try await precacheOne(deckId: deckId, deadline: deadline)
                completed.append(deckId)
            } catch {
                // Partial/cancelled — leave precachedAt nil; next run retries.
                break
            }
        }
        return completed
    }

    private func precacheOne(deckId: String, deadline: Date) async throws {
        try checkpoint(deadline)
        let deck = try await deckRepo.getDeck(id: deckId)
        upsertDeck(deck)

        let cards = try await cardRepo.listCards(deckId: deckId)
        for card in cards {
            try checkpoint(deadline)
            upsertCard(card)
            let images = try await imageRepo.listCardImages(cardId: card.id)
            for image in images {
                try checkpoint(deadline)
                upsertImage(image)
                // Download bytes into the blob (best-effort per image, but a
                // failure aborts this deck so precachedAt isn't stamped).
                let url = try await imageRepo.fileURL(for: image)
                let bytes = try await download(url)
                setBlob(imageId: image.id, bytes: bytes)
            }
        }

        // Full success → stamp precachedAt.
        stampPrecached(deckId: deckId, at: Date())
        try? context.save()
    }

    private func checkpoint(_ deadline: Date) throws {
        if Task.isCancelled { throw PrecacheError.cancelled }
        if Date() >= deadline { throw PrecacheError.deadlineExceeded }
    }

    // MARK: - Mirror writes (preserve local-only fields)

    private func upsertDeck(_ deck: Deck) {
        let id = deck.id
        if let row = try? context.fetch(FetchDescriptor<LocalDeck>(predicate: #Predicate { $0.id == id })).first {
            row.apply(deck)
        } else {
            context.insert(LocalDeck(
                id: deck.id, owner: deck.owner, name: deck.name, shootDate: deck.shootDate,
                clientUpdatedAt: deck.clientUpdatedAt, created: deck.created,
                updated: deck.updated, deletedAt: deck.deletedAt
            ))
        }
    }

    private func upsertCard(_ card: Card) {
        let id = card.id
        if let row = try? context.fetch(FetchDescriptor<LocalCard>(predicate: #Predicate { $0.id == id })).first {
            row.apply(card)
        } else {
            context.insert(LocalCard(
                id: card.id, deck: card.deck, position: card.position, title: card.title,
                timeSlot: card.timeSlot, subjects: card.subjects, direction: card.direction,
                notes: card.notes, clientUpdatedAt: card.clientUpdatedAt, created: card.created,
                updated: card.updated, deletedAt: card.deletedAt
            ))
        }
    }

    private func upsertImage(_ image: CardImage) {
        let id = image.id
        if let row = try? context.fetch(FetchDescriptor<LocalCardImage>(predicate: #Predicate { $0.id == id })).first {
            row.apply(image)
        } else {
            context.insert(LocalCardImage(
                id: image.id, card: image.card, position: image.position,
                file: image.file, created: image.created
            ))
        }
    }

    private func setBlob(imageId: String, bytes: Data) {
        // `[GAUNTLET poisoned-cache]` Reject bytes that don't decode to a complete
        // image so a truncated download / error body can't poison the offline
        // mirror (the same gate `SwiftDataLocalStore.cacheImageBlob` applies on
        // the read-path writeback). Without this the precache was a second poison
        // vector feeding ProtectedAsyncImage's cache-first read.
        guard ImageCompressor.canDecode(bytes) else { return }
        let id = imageId
        guard let row = try? context.fetch(FetchDescriptor<LocalCardImage>(predicate: #Predicate { $0.id == id })).first else {
            return
        }
        row.blob = bytes
        row.isCached = true
    }

    private func stampPrecached(deckId: String, at date: Date) {
        let id = deckId
        if let row = try? context.fetch(FetchDescriptor<LocalDeck>(predicate: #Predicate { $0.id == id })).first {
            row.precachedAt = date
        }
    }
}
