import Foundation
import Observation
import PoseDeckCore

/// Drives an iOS shoot session (DESIGN.md §4.2): owns the pure ``ShootSession``
/// state machine, the frozen card snapshot, and the persistence + image bridges.
///
/// The session is a value type the view model mutates; every transition is
/// mirrored to the completion repository separately so the ordering logic stays
/// exhaustively unit-tested in PoseDeckCore and the persistence path (LWW
/// completions) is cleanly decoupled.
///
/// Shoot **order is per-device and ephemeral** — re-derived from `card.position`
/// on every launch and never synced. Only completion **state** crosses devices
/// (`[FIX-M6]`): hydrate seeds `doneIds`/`skippedActiveIds`, but the working
/// order always comes from the position-sorted snapshot.
@MainActor
@Observable
final class ShootModeViewModel {

    let deck: Deck
    /// Frozen, position-ordered, non-soft-deleted card snapshot (DESIGN.md §4.2:
    /// shoot mode is read-only in v1; live deletions/additions are ignored).
    private let cards: [Card]
    private let cardsById: [String: Card]
    @ObservationIgnored private let completionRepo: any CardCompletionRepositoring
    @ObservationIgnored private let imageRepo: any CardImageReading
    @ObservationIgnored private let userId: String

    /// Owns the lifecycle of the fire-and-forget persist + prefetch work so it is
    /// cancellable and coalesced rather than leaking past the screen
    /// (`[FIX-swift-4]`). Cancelled via ``cancelPendingWork()`` from the view's
    /// disappear hook.
    @ObservationIgnored private let scheduler = ShootTaskScheduler()

    /// The pure state machine the view drives.
    private(set) var session: ShootSession

    /// Cached first-image file URL per card id (minted lazily on demand).
    private(set) var imageURLByCard: [String: URL] = [:]

    init(
        deck: Deck,
        cards: [Card],
        completionRepo: any CardCompletionRepositoring,
        imageRepo: any CardImageReading,
        userId: String
    ) {
        self.deck = deck
        // Freeze the snapshot in position order, non-soft-deleted only.
        let ordered = cards
            .filter { $0.deletedAt == nil }
            .sorted { $0.position < $1.position }
        self.cards = ordered
        self.cardsById = Dictionary(uniqueKeysWithValues: ordered.map { ($0.id, $0) })
        self.completionRepo = completionRepo
        self.imageRepo = imageRepo
        self.userId = userId
        self.session = ShootSession(cardIds: ordered.map(\.id))
    }

    // MARK: - Derived view state

    /// The card currently presented, or `nil` when complete.
    var currentCard: Card? {
        guard let id = session.currentCardId else { return nil }
        return cardsById[id]
    }

    /// "Card N of M" (cursor-position model, `[FIX-M2a]`).
    var progressText: String {
        let p = session.progress
        return "Card \(p.position) of \(p.total)"
    }

    var skippedCount: Int { session.skippedCount }
    var canUndo: Bool { session.canUndo }
    var isComplete: Bool { session.isComplete }

    /// Cached first-image URL for the current card, if loaded.
    var currentImageURL: URL? {
        guard let id = session.currentCardId else { return nil }
        return imageURLByCard[id]
    }

    // MARK: - Lifecycle

    /// Tracks whether prior progress has been hydrated, so the async hydration
    /// runs **once** and can never clobber a session the user has already started
    /// acting on (the hydration fetch is async; without this guard a slow fetch
    /// could reset a `done`/`skip` the user tapped while it was in flight).
    @ObservationIgnored private var didHydrate = false

    /// Hydrate prior progress (done/skipped state) on load, seeding the session,
    /// then prefetch the current + next card images.
    func load() async {
        let cardIds = cards.map(\.id)
        let prior = (try? await completionRepo.completions(forCardIds: cardIds, userId: userId)) ?? []
        // Only seed if the user hasn't already acted (no undo history) and we
        // haven't hydrated yet — the fetch is async, so a tap may have landed
        // first. Re-seeding then would silently revert that action.
        if !didHydrate, session.canUndo == false, session.doneIds.isEmpty, session.skippedActiveIds.isEmpty {
            var doneIds: Set<String> = []
            var skippedIds: Set<String> = []
            for completion in prior {
                switch completion.state {
                case .done: doneIds.insert(completion.card)
                case .skipped: skippedIds.insert(completion.card)
                case .pending: break
                }
            }
            if !doneIds.isEmpty || !skippedIds.isEmpty {
                session = ShootSession(cardIds: cardIds, doneIds: doneIds, skippedActiveIds: skippedIds)
            }
        }
        didHydrate = true
        await prefetchImages()
    }

    // MARK: - Transitions (session + persist)

    /// Mark the current card done (swipe right) and persist `.done`.
    func done() {
        guard let cardId = session.currentCardId else { return }
        session.markDone()
        persist(cardId: cardId) { try await $0.markDone(cardId: cardId, userId: $1) }
        scheduler.coalesce { [weak self] in await self?.prefetchImages() }
    }

    /// Skip the current card to the end (swipe left) and persist `.skipped`.
    func skip() {
        guard let cardId = session.currentCardId else { return }
        session.skip()
        persist(cardId: cardId) { try await $0.markSkipped(cardId: cardId, userId: $1) }
        scheduler.coalesce { [weak self] in await self?.prefetchImages() }
    }

    /// Reverse the most recent transition and persist the reversed card back to
    /// `pending`. The popped frame's card id is read **before** the session undo
    /// so we know which card to clear (`[FIX-M6]`: STATE convergence only —
    /// order is always re-derived per-device).
    func undo() {
        guard let reversedCardId = poppedCardId() else { return }
        session.undo()
        persist(cardId: reversedCardId) { try await $0.clearCompletion(cardId: reversedCardId, userId: $1) }
        scheduler.coalesce { [weak self] in await self?.prefetchImages() }
    }

    /// Cancel all outstanding persist + prefetch work. Driven from the view's
    /// disappear hook so dismissing the shoot screen tears down in-flight image
    /// fetches and completion writes instead of letting them outlive the screen
    /// (`[FIX-swift-4]`).
    func cancelPendingWork() {
        scheduler.cancelAll()
    }

    /// The card id the top undo frame would reverse, without mutating the session.
    private func poppedCardId() -> String? {
        guard let frame = session.undoStack.last else { return nil }
        switch frame {
        case let .done(cardId, _): return cardId
        case let .skip(cardId, _, _): return cardId
        }
    }

    /// Persist a completion change off the calling path. `[FIX-m2]`: skip writing
    /// a completion for a card soft-deleted in the local mirror (the frozen
    /// snapshot ignores live deletions, so we must not fabricate zombie progress).
    private func persist(
        cardId: String,
        // `@MainActor`-isolated: `CardCompletionRepositoring` is itself a
        // `@MainActor` protocol, so `repo` never leaves the main actor. Marking
        // the op main-actor-isolated (rather than a bare nonisolated `@Sendable`)
        // is what keeps it data-race-safe under Swift 6 / strict concurrency: a
        // nonisolated closure would have to *send* the main-actor `repo` ($0)
        // into itself to call `markDone`/`markSkipped`/`clearCompletion`, which
        // the compiler correctly rejects as a cross-actor send.
        _ op: @escaping @MainActor @Sendable (any CardCompletionRepositoring, String) async throws -> CardCompletion
    ) {
        let repo = completionRepo
        let userId = self.userId
        // Route through the scheduler so the write is retained in a cancellable
        // bag and torn down with the screen (`[FIX-swift-4]`).
        scheduler.persist { [weak self] in
            // The snapshot is frozen, but a card could be soft-deleted in the
            // mirror mid-shoot; the snapshot's `deletedAt` is the read at session
            // start. Honour the live snapshot's view: cards we hold are non-deleted.
            guard let self, self.cardsById[cardId] != nil else { return }
            try? await op(repo, userId)
        }
    }

    // MARK: - Images

    /// Mint first-image URLs for the current and next presentable cards so the
    /// view renders without a per-card fetch flash. Best-effort.
    private func prefetchImages() async {
        for cardId in presentableLookahead() where imageURLByCard[cardId] == nil {
            guard let images = try? await imageRepo.listCardImages(cardId: cardId),
                  let first = images.first,
                  let url = try? await imageRepo.fileURL(for: first) else { continue }
            imageURLByCard[cardId] = url
        }
    }

    /// The current card id plus a small lookahead of not-yet-done cards.
    private func presentableLookahead() -> [String] {
        guard let current = session.currentCardId,
              let idx = session.workingOrder.firstIndex(of: current) else { return [] }
        return Array(session.workingOrder[idx...].prefix(2))
    }
}
