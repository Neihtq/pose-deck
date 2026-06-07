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

    /// Set true when the session token is rejected mid-session (a 401 from
    /// realtime or the outbox). The UI observes this to drive a sign-out /
    /// re-login — the iOS counterpart of the web `clearAuthOnUnauthorized`
    /// (swift-4). Realtime stops and the outbox stays paused on a dead token,
    /// so this flag is the signal that the session must be re-established
    /// rather than silently going stale until relaunch.
    private(set) var sessionExpired = false

    /// De-dupes the 401 signal so realtime + the outbox both reporting the
    /// same expiry only flips ``sessionExpired`` once.
    @ObservationIgnored private let expiryReporter: SessionExpiryReporter

    /// Bumps a debounced `revision` whenever the SwiftData mirror is written
    /// (realtime merge or outbox confirmation). Views read `ticker.revision` in a
    /// `.task(id:)` to re-query the mirror, so a remote create/edit/delete shows
    /// without a manual pull-to-refresh. This is the iOS counterpart of the web
    /// `useLiveQuery` reactive read.
    let ticker = MirrorChangeTicker()

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
        // Latch a single 401 episode and bounce it back onto the main actor so
        // the @Observable `sessionExpired` flip + the app hook run there. The
        // reporter is `nonisolated(unsafe)` set right after to break the
        // initializer's "self before all stored properties" rule cleanly.
        self.expiryReporter = SessionExpiryReporter()
        Task { [weak self] in
            await self?.installExpiryHandler()
        }
    }

    /// Wire the reporter's one-shot handler to the main-actor flag flip. Done
    /// after `init` so the `@Sendable` closure can capture `self` weakly.
    private func installExpiryHandler() async {
        await expiryReporter.setHandler { [weak self] in
            await self?.handleSessionExpired()
        }
    }

    /// Flip the observable flag exactly once per expiry. ``RootView`` observes
    /// `sessionExpired` and signs out (web parity), so the auth gate falls back
    /// to the login screen.
    private func handleSessionExpired() {
        sessionExpired = true
    }

    // MARK: - Lifecycle

    /// Begin syncing for an authenticated session: backfill → subscribe → drain.
    ///
    /// The token is read from the ``APIClient`` (the auth service already applied
    /// it on sign-in / restore), so this coordinator never owns or clears session
    /// state — that stays with ``AuthService``.
    func onAuthenticated(token: String?, ownerId: String) async {
        self.ownerId = ownerId
        // Fresh (re)auth: clear the latched 401 so a future expiry reports again,
        // un-pause the processor's dead-token gate, and reset the UI flag.
        sessionExpired = false
        await expiryReporter.reset()
        await processor.resumeAfterAuthRefresh()
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
        // Cancel any prior (possibly auth-paused / finished) drain loop so a
        // re-auth-in-place always gets a fresh loop — guards against a stale
        // finished handle making `startDrainLoop`'s `== nil` guard a no-op.
        drainLoop?.cancel()
        drainLoop = nil
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
        let reporter = self.expiryReporter
        let client = RealtimeClient(
            transport: transport,
            authToken: token,
            onEvent: { event in await engine.apply(event) },
            // A 401 on (re)connect stops realtime for good on a dead token.
            // Surface it so the app can sign out / re-auth instead of going
            // silently stale (swift-4 / web parity with clearAuthOnUnauthorized).
            onAuthFailed: { await reporter.reportExpired() }
        )
        realtime = client
        realtimeLoop = Task { await client.run() }
    }

    // MARK: - Backfill (reconciling resync, invariant #7)

    private func backfill(ownerId: String) async {
        let deckRepo = DeckRepository(client: apiClient)
        let cardRepo = CardRepository(client: apiClient)
        let completionRepo = CardCompletionRepository(client: apiClient)
        do {
            let live = try await deckRepo.listDecks()
            let trashed = try await deckRepo.listTrashedDecks()
            for deck in live + trashed {
                await store.upsertDeck(deck)
                let cards = try await cardRepo.listCards(deckId: deck.id)
                for card in cards { await store.upsertCard(card) }
            }
            // Seed prior shoot progress (so a fresh launch / second device sees
            // already-done/skipped cards). LWW-merged via `upsertCardCompletion`
            // so a stale baseline can't clobber a newer local action. `[FIX-C1]`
            // is what *closes* the empty-mirror race; this only narrows it.
            let completions = try await completionRepo.listCompletions(forUser: ownerId)
            for completion in completions { await store.upsertCardCompletion(completion) }
        } catch {
            // Offline / transient: the mirror keeps whatever it had; realtime +
            // the next foreground backfill will reconcile.
            #if DEBUG
            print("[SyncCoordinator] backfill failed: \(error)")
            #endif
        }
    }

    // MARK: - Outbox drain loop (external scheduler for the no-sleep processor)

    /// Clear the stored drain-loop handle from inside the loop's own teardown so
    /// `startDrainLoop`'s `drainLoop == nil` guard can restart it after an
    /// auth-paused exit. Runs on the main actor (the coordinator's isolation).
    private func clearDrainLoop() {
        drainLoop = nil
    }

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
                    // Dead token: the processor will keep returning .authPaused
                    // until resumeAfterAuthRefresh() is called, and no refresh
                    // happens here. Re-spinning every 5s does nothing useful, so
                    // surface the expiry (drives sign-out / re-login) and EXIT
                    // the loop rather than busy-idling forever (swift-4).
                    //
                    // Clear the stored handle on the way out: `startDrainLoop`
                    // guards on `drainLoop == nil`, so leaving a finished handle
                    // here would make a subsequent re-auth-in-place
                    // (`onAuthenticated` again, which calls
                    // `resumeAfterAuthRefresh()`) a silent no-op — the outbox
                    // would never drain again until relaunch. Nil it so the next
                    // `onAuthenticated`/`onScenePhase(.active)` restarts the loop.
                    await self?.clearDrainLoop()
                    await self?.expiryReporter.reportExpired()
                    return
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

        // SEC-2: null out the pre-cached image bytes BEFORE the bulk delete so
        // SwiftData reclaims their `.externalStorage` sidecar files. A bulk
        // `delete(model:)` does not reliably reclaim those sidecars eagerly, so
        // without this a previous user's cached `card_images` bytes can survive
        // as orphaned files in the shared (non-per-user) store directory.
        if let images = try? context.fetch(FetchDescriptor<LocalCardImage>()) {
            MirrorPurge.clearCachedBlobs(in: images)
            try? context.save()
        }

        for model in LocalMirrorStore.models {
            try? context.delete(model: model)
        }
        try? context.save()

        // SEC-IOS-1: also flush the shared HTTP response cache. Pre-cached and
        // AsyncImage-displayed protected `card_images` responses (?token= URLs)
        // are cached to URLCache.shared's process-global, non-per-user on-disk
        // store under their long-lived Cache-Control. The mirror is the intended
        // offline store (purged above), so the HTTP-cache copy is pure remanence
        // — a previous user's private image bytes left unencrypted in a shared
        // cache dir after sign-out. Clear it so the next user of a shared install
        // can't recover them.
        MirrorPurge.clearSharedHTTPCache(URLCache.shared)
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

    func makeCardCompletionRepository() -> MirrorCardCompletionRepository {
        MirrorCardCompletionRepository(store: store, outbox: outbox)
    }
}
