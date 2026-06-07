import SwiftUI
import PoseDeckCore

/// Deck-detail screen (DESIGN.md §3.3 / §4.1): the deck's cards in `position`
/// order with first-image thumbnails, drag-to-reorder (EditMode/`.onMove`),
/// swipe-to-delete (inline soft-delete, no need to open the card), an Add-card
/// action, and a header menu for rename / edit-date / duplicate / delete.
///
/// Navigation: tapping a card row or "Add card" routes through
/// `cardEditorFactory` — the card-editor screen is owned by a sibling unit and
/// injected here as a view builder. See `followups` for the intended wiring
/// (an existing card → editor in edit mode; a `nil` card → editor in create
/// mode). NO shoot mode here (that is M4).
struct DeckDetailView: View {
    @State private var model: DeckDetailViewModel
    /// Bumps `revision` after a realtime merge / outbox confirmation writes the
    /// SwiftData mirror, so this open detail screen re-queries its cards without a
    /// manual pull. Optional (nil in previews / fakes, which have no live mirror).
    private let ticker: MirrorChangeTicker?
    /// Builds the card editor for a given card (`nil` = create a new card).
    private let cardEditorFactory: (Card?) -> AnyView
    /// Builds the shoot-mode screen for the deck + a snapshot of its current
    /// cards (same injection pattern as `cardEditorFactory`). M4 §4.2.
    private let shootModeFactory: (Deck, [Card]) -> AnyView

    @Environment(\.dismiss) private var dismiss
    @State private var editMode: EditMode = .inactive
    @State private var showDeleteConfirm = false
    /// Navigation routing for the card editor + shoot mode + share.
    ///
    /// Share is presented as a PUSHED destination (not a `.sheet`): an optimistic
    /// grant writes the SwiftData mirror, which bumps the deck-list ticker and
    /// re-renders the list body — that rebuilds this pushed `DeckDetailView` and
    /// tears down any attached `.sheet`, dismissing the share UI mid-grant. A
    /// navigationDestination is keyed by the route value and survives the parent
    /// re-render, so the share screen stays put while guests are added/revoked.
    private enum CardRoute: Hashable {
        case existing(Card)
        case new
        case shoot
        case share
    }
    @State private var cardRoute: CardRoute?

    init(
        model: DeckDetailViewModel,
        ticker: MirrorChangeTicker? = nil,
        cardEditorFactory: @escaping (Card?) -> AnyView,
        shootModeFactory: @escaping (Deck, [Card]) -> AnyView = { _, _ in AnyView(EmptyView()) }
    ) {
        self._model = State(initialValue: model)
        self.ticker = ticker
        self.cardEditorFactory = cardEditorFactory
        self.shootModeFactory = shootModeFactory
    }

    var body: some View {
        @Bindable var model = model
        return content
            .navigationTitle(model.deck.name)
            .navigationBarTitleDisplayMode(.inline)
            .environment(\.editMode, $editMode)
            .toolbar { toolbarContent }
            .navigationDestination(item: $cardRoute) { route in
                switch route {
                case .existing(let card): cardEditorFactory(card)
                case .new: cardEditorFactory(nil)
                case .shoot: shootModeFactory(model.deck, model.cards)
                case .share: ShareDeckView(model: model, ticker: ticker)
                }
            }
            .sheet(isPresented: Binding(
                get: { model.activeSheet == .edit },
                set: { if !$0 { model.activeSheet = nil } }
            )) {
                DeckEditorSheet(
                    title: "Edit Deck",
                    initialName: model.deck.name,
                    initialDate: model.deck.shootDate,
                    onSave: { name, date in
                        model.activeSheet = nil
                        Task { await model.applyEdit(name: name, shootDate: date) }
                    },
                    onCancel: { model.activeSheet = nil }
                )
            }
            .confirmationDialog(
                "Move this deck to Trash?",
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Move to Trash", role: .destructive) {
                    Task { await model.softDeleteDeck() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("\"\(model.deck.name)\" can be restored from Trash for 30 days.")
            }
            .alert(
                "Error",
                isPresented: Binding(
                    get: { model.actionError != nil },
                    set: { if !$0 { model.actionError = nil } }
                ),
                presenting: model.actionError
            ) { _ in
                Button("OK", role: .cancel) { model.actionError = nil }
            } message: { msg in Text(msg) }
            .task { await model.load() }
            // Reactive re-query: the ticker bumps `revision` after a realtime
            // merge / outbox confirmation writes the mirror, so a remote
            // card/deck change refreshes this open screen without a manual pull.
            // `refresh()` avoids the full-screen loading flip; the `revision == 0`
            // skip avoids a redundant reload on first render. iOS counterpart of
            // the web `useLiveQuery` reactive read.
            .task(id: ticker?.revision) {
                if let revision = ticker?.revision, revision > 0 {
                    await model.refresh()
                }
            }
            .onChange(of: model.didDelete) { _, deleted in
                if deleted { dismiss() }
            }
            .onChange(of: cardRoute) { _, route in
                // Returning from the editor: refresh so new/edited cards show.
                if route == nil { Task { await model.refresh() } }
            }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if !model.isEmpty {
            ToolbarItem(placement: .topBarLeading) {
                Button { cardRoute = .shoot } label: {
                    Label("Start shoot", systemImage: "camera")
                }
                .accessibilityIdentifier("deck.startShoot")
            }
        }
        // Editing (reorder / swipe-delete) and the deck-actions menu are
        // owner-only — a guest's deck-detail is read-only (`[FIX #3-iOS]` /
        // owner-gating). A guest sees no Edit / Share / Rename / Delete.
        if model.isOwner {
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
                    .accessibilityIdentifier("deck.editButton")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { cardRoute = .share } label: {
                        Label("Share", systemImage: "person.crop.circle.badge.plus")
                    }
                    .accessibilityIdentifier("deck.share")
                    Button { model.activeSheet = .edit } label: {
                        Label("Rename / Date", systemImage: "pencil")
                    }
                    Button { Task { await model.duplicateDeck() } } label: {
                        Label("Duplicate", systemImage: "doc.on.doc")
                    }
                    Divider()
                    Button(role: .destructive) { showDeleteConfirm = true } label: {
                        Label("Delete", systemImage: "trash")
                    }
                } label: {
                    Label("Deck actions", systemImage: "ellipsis.circle")
                }
                .accessibilityIdentifier("deck.actionsMenu")
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle:
            ProgressView("Loading cards…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loading where model.isEmpty:
            ProgressView("Loading cards…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message) where model.isEmpty:
            ContentUnavailableView {
                Label("Couldn't load cards", systemImage: "exclamationmark.triangle")
            } description: { Text(message) } actions: {
                Button("Retry") { Task { await model.load() } }
            }
        default:
            cardList
        }
    }

    @ViewBuilder
    private var cardList: some View {
        if model.isEmpty {
            ContentUnavailableView {
                Label("No cards yet", systemImage: "rectangle.on.rectangle.angled")
            } description: {
                Text(model.isOwner
                     ? "Add a card to start building this shotlist."
                     : "This deck has no cards yet.")
            } actions: {
                if model.isOwner {
                    Button("Add Card") { cardRoute = .new }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("deck.addCard.empty")
                }
            }
        } else {
            List {
                Section {
                    ForEach(model.cards) { card in
                        Button { cardRoute = .existing(card) } label: {
                            CardRowView(
                                card: card,
                                thumbnailURL: model.thumbnailURLs[card.id],
                                onThumbnailFailure: { await model.refreshThumbnail(for: card) }
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("card.row.\(card.title)")
                    }
                    // Card edits (delete / reorder) are owner-only; a guest's
                    // deck-detail is read-only (owner-gating).
                    .onDelete(perform: model.isOwner ? { offsets in
                        Task { await model.deleteCard(at: offsets) }
                    } : nil)
                    .onMove(perform: model.isOwner ? { source, dest in
                        Task { await model.moveCards(from: source, to: dest) }
                    } : nil)
                    // Disable drag while a reorder is being persisted so a new
                    // drop can't stack on an unconfirmed one (mirrors the web
                    // `dragDisabled={reordering}`). The model also guards this.
                    .moveDisabled(model.isReordering || !model.isOwner)
                }
                if model.isOwner {
                    Section {
                        Button { cardRoute = .new } label: {
                            Label("Add Card", systemImage: "plus")
                        }
                        .accessibilityIdentifier("deck.addCard")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .refreshable { await model.refresh() }
        }
    }
}

/// A card row: first-image thumbnail (or placeholder), title, and a one-line
/// summary of time slot / subjects.
struct CardRowView: View {
    let card: Card
    let thumbnailURL: URL?
    /// Called when the thumbnail's `AsyncImage` reports `.failure` so the owner
    /// can re-mint an expired file token (defaults to a no-op for previews).
    var onThumbnailFailure: () async -> Void = {}

    private var summary: String? {
        let parts = [card.timeSlot, card.subjects]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 2) {
                Text(card.title.isEmpty ? "Untitled card" : card.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(card.title.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                if let summary {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var thumbnail: some View {
        let size: CGFloat = 52
        Group {
            if let thumbnailURL {
                // Protected token-bearing URL — non-persisting session (SEC-IOS-B).
                ProtectedAsyncImage(url: thumbnailURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure:
                        placeholder
                            // Most commonly an expired short-lived file
                            // `?token=` on a long-lived detail screen — ask the
                            // owner to re-mint it (mirrors the editor's
                            // `CardImagesSection` `.failure` → `refreshURL`).
                            .task { await onThumbnailFailure() }
                    default:
                        ProgressView()
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var placeholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.quaternary)
            Image(systemName: "photo")
                .foregroundStyle(.secondary)
        }
    }
}

extension DeckDetailView {
    /// Offline placeholder detail view for previews/navigation fallbacks.
    static var previewPlaceholder: DeckDetailView {
        DeckDetailView(
            model: DeckDetailViewModel(
                deck: Deck(id: "d0", owner: "u1", name: "Deck"),
                deckRepo: FakeDeckRepository(),
                cardRepo: FakeCardRepository(cardsByDeck: [:]),
                imageRepo: FakeCardImageRepository(),
                ownerId: "u1"
            ),
            cardEditorFactory: { _ in AnyView(Text("Card editor")) }
        )
    }
}

#Preview("With cards") {
    NavigationStack {
        DeckDetailView(
            model: DeckDetailViewModel(
                deck: FakeDeckRepository.sample[0],
                deckRepo: FakeDeckRepository(),
                cardRepo: FakeCardRepository(),
                imageRepo: FakeCardImageRepository(),
                ownerId: "u1"
            ),
            cardEditorFactory: { card in
                AnyView(Text(card == nil ? "New card" : "Edit \(card!.title)"))
            }
        )
    }
}

#Preview("Empty deck") {
    NavigationStack {
        DeckDetailView(
            model: DeckDetailViewModel(
                deck: Deck(id: "dX", owner: "u1", name: "Empty Deck"),
                deckRepo: FakeDeckRepository(),
                cardRepo: FakeCardRepository(cardsByDeck: [:]),
                imageRepo: FakeCardImageRepository(),
                ownerId: "u1"
            ),
            cardEditorFactory: { _ in AnyView(Text("Card editor")) }
        )
    }
}
