import SwiftUI
import PoseDeckCore

/// Composition root + auth gate for the app.
///
/// Owns the single shared ``APIClient`` and ``AuthService`` and decides which
/// top-level screen to show based on the observable session state:
///  - signed out → ``LoginView``
///  - signed in  → the deck list (``DeckListView``, which hosts its own
///    `NavigationStack`), with deck-detail and card-editor destinations wired
///    through factory closures, plus Trash (mounted inside ``DeckListView``) and
///    a Sign Out affordance.
///
/// Repositories are constructed here from the shared client and the authenticated
/// user id so every screen mutates through the same backend with the correct
/// `owner` stamping.
struct RootView: View {
    private let apiClient: APIClient
    @State private var auth: AuthService
    /// Tracks whether the launch-time session restore has completed so we don't
    /// flash the login screen before the keychain is consulted.
    @State private var didAttemptRestore = false

    init(apiClient: APIClient, authService: AuthService) {
        self.apiClient = apiClient
        self._auth = State(initialValue: authService)
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
    }

    // MARK: - Authenticated content

    private func deckList(ownerId: String) -> some View {
        let deckRepo = DeckRepository(client: apiClient)
        let model = DeckListViewModel(repo: deckRepo, ownerId: ownerId)
        return DeckListView(
            model: model,
            detailFactory: { deck in
                makeDetail(deck: deck, ownerId: ownerId)
            },
            onSignOut: {
                Task { await auth.signOut() }
            }
        )
    }

    private func makeDetail(deck: Deck, ownerId: String) -> DeckDetailView {
        let deckRepo = DeckRepository(client: apiClient)
        let cardRepo = CardRepository(client: apiClient)
        let imageRepo = ImageRepository(client: apiClient)
        let detailModel = DeckDetailViewModel(
            deck: deck,
            deckRepo: deckRepo,
            cardRepo: cardRepo,
            imageRepo: imageRepo,
            ownerId: ownerId
        )
        let client = apiClient
        return DeckDetailView(
            model: detailModel,
            cardEditorFactory: { card in
                AnyView(
                    CardEditorHost(
                        deckId: deck.id,
                        cardId: card?.id,
                        cardRepo: cardRepo,
                        apiClient: client
                    )
                )
            }
        )
    }
}

/// Bridges the injected ``CardEditorView`` (which signals completion via an
/// `onClose` closure) onto the deck-detail `NavigationStack`: it captures the
/// environment `dismiss` so an edit-mode save or a delete pops back to the deck.
private struct CardEditorHost: View {
    @Environment(\.dismiss) private var dismiss

    let deckId: String
    let cardId: String?
    let cardRepo: CardRepository
    let apiClient: APIClient

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
                    repository: ImageRepository(client: apiClient)
                )
            },
            onClose: { dismiss() }
        )
    }
}
