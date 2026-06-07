import SwiftUI
import PoseDeckCore

/// Root deck-list screen (DESIGN.md §3.3): decks grouped Upcoming / Undated /
/// Past, searchable by name, with pull-to-refresh, a New-deck flow, a Trash
/// view, and per-deck actions (rename/edit-date, duplicate, soft-delete).
///
/// Tapping a row pushes ``DeckDetailView``. Navigation is hosted here via a
/// `NavigationStack` with `Deck` value destinations; the integration agent may
/// instead host this inside an app-level stack — see `followups`.
struct DeckListView: View {
    @State private var model: DeckListViewModel
    /// Bumps `revision` after a realtime merge / outbox confirmation writes the
    /// SwiftData mirror, so this list re-queries without a manual pull. Optional
    /// (nil in previews / fakes, which have no live mirror).
    private let ticker: MirrorChangeTicker?
    /// Factory the detail screen needs (card repo + image reader + owner id).
    private let detailFactory: (Deck) -> DeckDetailView
    /// Optional sign-out action shown in the toolbar (wired by the app root).
    private let onSignOut: (() -> Void)?

    /// Sheet/alert presentation state.
    private enum ActiveSheet: Identifiable {
        case newDeck
        case edit(Deck)
        var id: String {
            switch self {
            case .newDeck: return "new"
            case .edit(let d): return "edit-\(d.id)"
            }
        }
    }
    @State private var activeSheet: ActiveSheet?
    @State private var deckPendingDelete: Deck?
    @State private var showTrash = false

    init(
        model: DeckListViewModel,
        ticker: MirrorChangeTicker? = nil,
        detailFactory: @escaping (Deck) -> DeckDetailView,
        onSignOut: (() -> Void)? = nil
    ) {
        self._model = State(initialValue: model)
        self.ticker = ticker
        self.detailFactory = detailFactory
        self.onSignOut = onSignOut
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Decks")
                .navigationDestination(for: Deck.self) { deck in
                    detailFactory(deck)
                }
                .searchable(text: $model.searchText, prompt: "Search decks")
                .toolbar { toolbarContent }
                .sheet(item: $activeSheet) { sheet in
                    switch sheet {
                    case .newDeck:
                        DeckEditorSheet(
                            title: "New Deck",
                            saveLabel: "Create",
                            onSave: { name, date in
                                activeSheet = nil
                                Task { await model.createDeck(name: name, shootDate: date) }
                            },
                            onCancel: { activeSheet = nil }
                        )
                    case .edit(let deck):
                        DeckEditorSheet(
                            title: "Edit Deck",
                            initialName: deck.name,
                            initialDate: deck.shootDate,
                            onSave: { name, date in
                                activeSheet = nil
                                Task { await model.applyEdit(deck, name: name, shootDate: date) }
                            },
                            onCancel: { activeSheet = nil }
                        )
                    }
                }
                .sheet(isPresented: $showTrash) {
                    TrashView(repo: model.repository, ownerId: model.owner)
                        .onDisappear { Task { await model.load() } }
                }
                .confirmationDialog(
                    "Move this deck to Trash?",
                    isPresented: Binding(
                        get: { deckPendingDelete != nil },
                        set: { if !$0 { deckPendingDelete = nil } }
                    ),
                    titleVisibility: .visible,
                    presenting: deckPendingDelete
                ) { deck in
                    Button("Move to Trash", role: .destructive) {
                        Task { await model.softDelete(deck) }
                        deckPendingDelete = nil
                    }
                    Button("Cancel", role: .cancel) { deckPendingDelete = nil }
                } message: { deck in
                    Text("\"\(deck.name)\" can be restored from Trash for 30 days.")
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
                } message: { msg in
                    Text(msg)
                }
        }
        .task { await model.load() }
        // Reactive re-query: the ticker bumps `revision` after a realtime merge /
        // outbox confirmation writes the mirror, so a remote create/edit/delete
        // shows without a manual pull. `refresh()` avoids the full-screen loading
        // flip. The `revision == 0` skip avoids a redundant reload on first render
        // (the initial `load()` above already covers it). iOS counterpart of the
        // web `useLiveQuery` reactive read.
        .task(id: ticker?.revision) {
            if let revision = ticker?.revision, revision > 0 {
                await model.refresh()
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                showTrash = true
            } label: {
                Label("Trash", systemImage: "trash")
            }
            .accessibilityIdentifier("decks.trash")
        }
        if let onSignOut {
            ToolbarItem(placement: .topBarLeading) {
                Button(role: .destructive) {
                    onSignOut()
                } label: {
                    Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                }
                .accessibilityIdentifier("decks.signOut")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                activeSheet = .newDeck
            } label: {
                Label("New Deck", systemImage: "plus")
            }
            .accessibilityIdentifier("decks.new")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle:
            ProgressView("Loading decks…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loading where model.isEmpty:
            ProgressView("Loading decks…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message) where model.isEmpty:
            ContentUnavailableView {
                Label("Couldn't load decks", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Retry") { Task { await model.load() } }
            }
        default:
            deckList
        }
    }

    @ViewBuilder
    private var deckList: some View {
        let grouped = model.grouped
        if grouped.upcoming.isEmpty, grouped.undated.isEmpty, grouped.past.isEmpty {
            emptyState
        } else {
            List {
                section("Upcoming", grouped.upcoming)
                section("Undated", grouped.undated)
                section("Past", grouped.past)
            }
            .listStyle(.insetGrouped)
            .refreshable { await model.refresh() }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.searchText.isEmpty {
            ContentUnavailableView {
                Label("No decks yet", systemImage: "rectangle.stack.badge.plus")
            } description: {
                Text("Create your first shotlist to get started.")
            } actions: {
                Button("New Deck") { activeSheet = .newDeck }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            ContentUnavailableView.search(text: model.searchText)
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ decks: [Deck]) -> some View {
        if !decks.isEmpty {
            Section(title) {
                ForEach(decks) { deck in
                    NavigationLink(value: deck) {
                        DeckRow(deck: deck)
                    }
                    .accessibilityIdentifier("deck.row.\(deck.name)")
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            deckPendingDelete = deck
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        Button {
                            Task { await model.duplicate(deck) }
                        } label: {
                            Label("Duplicate", systemImage: "doc.on.doc")
                        }
                        .tint(.indigo)
                    }
                    .contextMenu {
                        Button {
                            activeSheet = .edit(deck)
                        } label: {
                            Label("Rename / Date", systemImage: "pencil")
                        }
                        Button {
                            Task { await model.duplicate(deck) }
                        } label: {
                            Label("Duplicate", systemImage: "doc.on.doc")
                        }
                        Button(role: .destructive) {
                            deckPendingDelete = deck
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        }
    }
}

/// A single deck row: name + shoot-date subtitle.
struct DeckRow: View {
    let deck: Deck

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(deck.name)
                .font(.body.weight(.medium))
                .lineLimit(1)
            Text(DeckFormatting.subtitle(for: deck))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

#Preview("Populated") {
    let repo = FakeDeckRepository()
    return DeckListView(
        model: DeckListViewModel(repo: repo, ownerId: "u1"),
        detailFactory: { deck in
            DeckDetailView(
                model: DeckDetailViewModel(
                    deck: deck,
                    deckRepo: repo,
                    cardRepo: FakeCardRepository(),
                    imageRepo: FakeCardImageRepository(),
                    ownerId: "u1"
                ),
                cardEditorFactory: { _ in AnyView(Text("Card editor")) }
            )
        }
    )
}

#Preview("Empty") {
    let repo = FakeDeckRepository(decks: [])
    return DeckListView(
        model: DeckListViewModel(repo: repo, ownerId: "u1"),
        detailFactory: { _ in DeckDetailView.previewPlaceholder }
    )
}
