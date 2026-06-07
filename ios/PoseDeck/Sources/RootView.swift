import SwiftUI
import PoseDeckCore

/// Composition root + auth gate for the app.
///
/// Owns the shared ``APIClient``, ``AuthService``, and ``SyncCoordinator`` and
/// decides which top-level screen to show based on the observable session state:
///  - signed out → ``LoginView``
///  - signed in  → the deck list (``DeckListView``, which hosts its own
///    `NavigationStack`), with deck-detail and card-editor destinations wired
///    through factory closures, plus Trash (mounted inside ``DeckListView``) and
///    a Sign Out affordance.
///
/// Repositories are now **mirror-backed** (offline-first): every screen reads
/// from the SwiftData mirror and writes optimistically through the outbox, built
/// from the ``SyncCoordinator`` rather than the raw API client. The coordinator
/// is driven through the auth/scene lifecycle so the mirror backfills, realtime
/// connects, and the outbox drains for the signed-in session.
struct RootView: View {
    private let apiClient: APIClient
    @State private var auth: AuthService
    @State private var sync: SyncCoordinator
    @Environment(\.scenePhase) private var scenePhase
    /// Tracks whether the launch-time session restore has completed so we don't
    /// flash the login screen before the keychain is consulted.
    @State private var didAttemptRestore = false
    /// Tracks whether the sync lifecycle has started for the current session, so
    /// we start it exactly once per sign-in.
    @State private var didStartSync = false

    init(apiClient: APIClient, authService: AuthService, sync: SyncCoordinator) {
        self.apiClient = apiClient
        self._auth = State(initialValue: authService)
        self._sync = State(initialValue: sync)
    }

    var body: some View {
        Group {
            if !didAttemptRestore {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if auth.isAuthenticated, let ownerId = auth.currentUserId {
                deckList(ownerId: ownerId)
            } else {
                LoginView(session: auth)
            }
        }
        .task {
            // Restore a persisted session (if any) before deciding what to show.
            if !didAttemptRestore {
                await auth.restore()
                didAttemptRestore = true
            }
        }
        // Drive the sync lifecycle off the observable auth state: start on the
        // first authenticated render, tear down (await quiesce + purge) on signout.
        .task(id: auth.isAuthenticated) {
            if auth.isAuthenticated, let ownerId = auth.currentUserId, !didStartSync {
                didStartSync = true
                // Token is read from the API client inside the coordinator (the
                // auth service already applied it on sign-in / restore).
                await sync.onAuthenticated(token: nil, ownerId: ownerId)
            } else if !auth.isAuthenticated, didStartSync {
                didStartSync = false
                await sync.onSignedOut()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            sync.onScenePhase(phase)
        }
        // A mid-session 401 (realtime or outbox) flips this flag. Mirror the web
        // `clearAuthOnUnauthorized` behaviour: drop the rejected session so the
        // auth gate falls back to LoginView instead of silently going stale.
        .onChange(of: sync.sessionExpired) { _, expired in
            if expired, auth.isAuthenticated {
                Task { await auth.signOut() }
            }
        }
    }

    // MARK: - Authenticated content

    private func deckList(ownerId: String) -> some View {
        let deckRepo = sync.makeDeckRepository()
        let model = DeckListViewModel(repo: deckRepo, ownerId: ownerId)
        return DeckListView(
            model: model,
            // Re-query the mirror when a realtime merge / outbox confirmation
            // writes it (the ticker debounces a burst into one bump), so remote
            // changes appear without a manual pull-to-refresh.
            ticker: sync.ticker,
            detailFactory: { deck in
                makeDetail(deck: deck, ownerId: ownerId)
            },
            onSignOut: {
                Task { await auth.signOut() }
            }
        )
    }

    private func makeDetail(deck: Deck, ownerId: String) -> DeckDetailView {
        let deckRepo = sync.makeDeckRepository()
        let cardRepo = sync.makeCardRepository()
        let imageRepo = sync.makeImageRepository()
        let detailModel = DeckDetailViewModel(
            deck: deck,
            deckRepo: deckRepo,
            cardRepo: cardRepo,
            imageRepo: imageRepo,
            ownerId: ownerId
        )
        return DeckDetailView(
            model: detailModel,
            // Same reactive re-query as the list: a realtime card/deck merge
            // refreshes this open detail screen without a manual pull.
            ticker: sync.ticker,
            cardEditorFactory: { card in
                AnyView(
                    CardEditorHost(
                        deckId: deck.id,
                        cardId: card?.id,
                        cardRepo: cardRepo,
                        imageRepo: imageRepo
                    )
                )
            }
        )
    }
}

/// Bridges the injected ``CardEditorView`` (which signals completion via an
/// `onClose` closure) onto the deck-detail `NavigationStack`: it captures the
/// environment `dismiss` so an edit-mode save or a delete pops back to the deck.
///
/// Both the card repository and the image repository are the mirror-backed
/// (offline-first) implementations injected from the ``SyncCoordinator``.
private struct CardEditorHost: View {
    @Environment(\.dismiss) private var dismiss

    let deckId: String
    let cardId: String?
    let cardRepo: any CardRepositoring
    let imageRepo: MirrorImageRepository

    var body: some View {
        CardEditorView(
            model: CardEditorViewModel(
                deckId: deckId,
                cardId: cardId,
                repository: cardRepo
            ),
            makeImagesModel: { resolvedCardId in
                CardImagesViewModel(
                    cardId: resolvedCardId,
                    repository: imageRepo
                )
            },
            onClose: { dismiss() }
        )
    }
}
