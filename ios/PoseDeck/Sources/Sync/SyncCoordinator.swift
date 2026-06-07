import Foundation
import SwiftUI
import SwiftData
import PoseDeckCore

/// Owns the sync lifecycle for the app session (M3 plan, STEP 10).
///
/// Composes the PoseDeckCore engine pieces — ``SwiftDataOutbox``,
/// ``OutboxProcessor``, ``SyncEngine``, ``RealtimeClient`` — and drives them
/// against app lifecycle events:
///  - ``onAuthenticated(token:ownerId:)``: backfill the mirror, open the five
///    realtime subscriptions (subscribe-before-resync, invariant #6), and start
///    the outbox drain loop.
///  - ``onSignedOut()``: **await the processor quiescing before purging** the
///    mirror, and warn if unsynced entries would be lost (folds the
///    signout-data-loss finding).
///  - ``onScenePhase(_:)``: resume on `.active`, suspend + schedule a background
///    refresh on `.background`.
///
/// The processor never sleeps inside its actor, so this coordinator is the
/// external scheduler: it loops `drain()` and, on a `.deferred(until:)`,
/// `Task.sleep`s here (outside the actor) before re-invoking.
@MainActor
@Observable
final class SyncCoordinator {

    /// Surfaced to the UI so a signout that would lose queued writes can warn.
    private(set) var pendingUnsyncedCount = 0

    @ObservationIgnored private let container: ModelContainer
    @ObservationIgnored private let apiClient: APIClient
    @ObservationIgnored private let store: SwiftDataLocalStore
    @ObservationIgnored private let outbox: SwiftDataOutbox
    @ObservationIgnored private let engine: SyncEngine
    @ObservationIgnored private let processor: OutboxProcessor

    @ObservationIgnored private var realtime: RealtimeClient?
    @ObservationIgnored private var drainLoop: Task<Void, Never>?
    @ObservationIgnored private var realtimeLoop: Task<Void, Never>?
    @ObservationIgnored private var ownerId: String?

    init(container: ModelContainer, apiClient: APIClient) {
        self.container = container
        self.apiClient = apiClient
        let store = SwiftDataLocalStore(container: container)
        let outbox = SwiftDataOutbox(container: container)
        let engine = SyncEngine(store: store)
        self.store = store
        self.outbox = outbox
        self.engine = engine
        self.processor = OutboxProcessor(
            queue: outbox,
            sender: MutationSender(client: apiClient),
            onConfirmed: { [engine] confirmed in
                await engine.noteConfirmed(entity: confirmed.entity, recordId: confirmed.recordId)
            }
        )
    }

    // MARK: - Lifecycle

    /// Begin syncing for an authenticated session: backfill → subscribe → drain.
    ///
    /// The token is read from the ``APIClient`` (the auth service already applied
    /// it on sign-in / restore), so this coordinator never owns or clears session
    /// state — that stays with ``AuthService``.
    func onAuthenticated(token: String?, ownerId: String) async {
        self.ownerId = ownerId
        let activeToken: String?
        if let token {
            activeToken = token
        } else {
            activeToken = await apiClient.currentAuthToken()
        }

        // Subscribe-before-resync (invariant #6): open realtime first, then
        // backfill; the engine's apply is idempotent so the overlap is safe.
        startRealtime(token: activeToken)
        await backfill(ownerId: ownerId)
        startDrainLoop()
    }

    /// Sign out: stop realtime, await the processor draining (best-effort, with a
    /// short ceiling), warn if writes remain unsynced, then purge the mirror.
    func onSignedOut() async {
        await realtime?.stop()
        realtimeLoop?.cancel()
        realtimeLoop = nil
        drainLoop?.cancel()
        drainLoop = nil

        // Await quiesce BEFORE purge: try to flush queued writes so a signout
        // doesn't silently drop them. Bounded so a permanently-offline signout
        // still completes.
        await quiesceProcessor(maxPasses: 5)

        let remaining = await outbox.count()
        pendingUnsyncedCount = remaining
        if remaining > 0 {
            #if DEBUG
            print("[SyncCoordinator] signing out with \(remaining) unsynced outbox entries — they will be lost")
            #endif
        }

        await purgeMirror()
        // Note: the auth token is owned by AuthService (cleared in its
        // signOut()); the coordinator does not touch session state.
        ownerId = nil
    }

    /// React to scene-phase changes.
    func onScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            if ownerId != nil, drainLoop == nil { startDrainLoop() }
        case .background:
            drainLoop?.cancel()
            drainLoop = nil
            scheduleBackgroundRefresh()
        default:
            break
        }
    }

    // MARK: - Realtime

    private func startRealtime(token: String?) {
        let transport = URLSessionSSETransport(baseURL: apiClient.baseURL)
        let engine = self.engine
        let client = RealtimeClient(
            transport: transport,
            authToken: token,
            onEvent: { event in await engine.apply(event) },
            onAuthFailed: { /* token refresh seam — M4 wires real refresh */ }
        )
        realtime = client
        realtimeLoop = Task { await client.run() }
    }

    // MARK: - Backfill (reconciling resync, invariant #7)

    private func backfill(ownerId: String) async {
        let deckRepo = DeckRepository(client: apiClient)
        let cardRepo = CardRepository(client: apiClient)
        do {
            let live = try await deckRepo.listDecks()
            let trashed = try await deckRepo.listTrashedDecks()
            for deck in live + trashed {
                await store.upsertDeck(deck)
                let cards = try await cardRepo.listCards(deckId: deck.id)
                for card in cards { await store.upsertCard(card) }
            }
        } catch {
            // Offline / transient: the mirror keeps whatever it had; realtime +
            // the next foreground backfill will reconcile.
            #if DEBUG
            print("[SyncCoordinator] backfill failed: \(error)")
            #endif
        }
    }

    // MARK: - Outbox drain loop (external scheduler for the no-sleep processor)

    private func startDrainLoop() {
        guard drainLoop == nil else { return }
        let processor = self.processor
        drainLoop = Task { [weak self] in
            while !Task.isCancelled {
                let result = await processor.drain()
                await self?.refreshPendingCount()
                switch result {
                case .idle:
                    // Nothing to do; poll occasionally so a newly-enqueued write
                    // is picked up. (A push-wake seam can replace this later.)
                    try? await Task.sleep(for: .seconds(2))
                case .progressed:
                    continue
                case .deferred(let until):
                    let delay = max(0, until.timeIntervalSinceNow)
                    try? await Task.sleep(for: .seconds(delay))
                case .authPaused:
                    // Token refresh is an M4 seam; back off so we don't spin.
                    try? await Task.sleep(for: .seconds(5))
                }
            }
        }
    }

    /// Drive `drain()` to a non-progressing state a bounded number of times so a
    /// signout flushes what it can before purging.
    private func quiesceProcessor(maxPasses: Int) async {
        for _ in 0..<maxPasses {
            let result = await processor.drain()
            if case .progressed = result { continue }
            break
        }
        await refreshPendingCount()
    }

    private func refreshPendingCount() async {
        pendingUnsyncedCount = await outbox.count()
    }

    // MARK: - Purge

    private func purgeMirror() async {
        let context = ModelContext(container)
        for model in LocalMirrorStore.models {
            try? context.delete(model: model)
        }
        try? context.save()
    }

    // MARK: - Background refresh scheduling

    private func scheduleBackgroundRefresh() {
        let store = self.store
        BackgroundRefresh.precacheProvider = { [apiClient, container] in
            let decks = await store.allDecks()
            let pinned = Set(await store.pinnedDeckIds())
            let now = Date()
            let targets = PrecachePlan.decksToPrecache(decks: decks, pinnedIds: pinned, now: now)
            let next = PrecachePlan.nextRefreshDate(decks: decks, now: now)
            let service = PrecacheService(
                container: container,
                deckRepo: DeckRepository(client: apiClient),
                cardRepo: CardRepository(client: apiClient),
                imageRepo: ImageRepository(client: apiClient)
            )
            return (service: service, targets: targets, nextRefresh: next)
        }
        let decks = Task.detached { await self.store.allDecks() }
        Task {
            let all = await decks.value
            BackgroundRefresh.schedule(earliestBeginDate: PrecachePlan.nextRefreshDate(decks: all, now: Date()))
        }
    }

    // MARK: - Repository factories (mirror-backed)

    func makeDeckRepository() -> MirrorDeckRepository {
        MirrorDeckRepository(store: store, outbox: outbox)
    }

    func makeCardRepository() -> MirrorCardRepository {
        MirrorCardRepository(store: store, outbox: outbox)
    }

    func makeImageRepository() -> MirrorImageRepository {
        MirrorImageRepository(store: store, outbox: outbox, remote: ImageRepository(client: apiClient))
    }
}
