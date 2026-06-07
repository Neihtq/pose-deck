import SwiftUI
import PoseDeckCore

/// Trash screen: lists soft-deleted decks and restores them (DESIGN.md §3.3,
/// 30-day soft-delete). There is no hard-delete from the UI — restore is the
/// only action. Presented as a sheet from ``DeckListView``.
struct TrashView: View {
    @State private var model: TrashViewModel
    @Environment(\.dismiss) private var dismiss

    init(repo: DeckRepositoring, ownerId: String) {
        self._model = State(initialValue: TrashViewModel(repo: repo))
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Trash")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
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
        }
        .task { await model.load() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loading where model.decks.isEmpty:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message) where model.decks.isEmpty:
            ContentUnavailableView {
                Label("Couldn't load Trash", systemImage: "exclamationmark.triangle")
            } description: { Text(message) } actions: {
                Button("Retry") { Task { await model.load() } }
            }
        default:
            if model.decks.isEmpty {
                ContentUnavailableView {
                    Label("Trash is empty", systemImage: "trash")
                } description: {
                    Text("Deleted decks appear here and can be restored for 30 days.")
                }
            } else {
                List {
                    ForEach(model.decks) { deck in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(deck.name).font(.body.weight(.medium)).lineLimit(1)
                                Text(DeckFormatting.subtitle(for: deck))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Restore") { Task { await model.restore(deck) } }
                                .buttonStyle(.bordered)
                                .accessibilityIdentifier("trash.restore.\(deck.name)")
                        }
                    }
                }
            }
        }
    }
}

/// View model for ``TrashView``.
@MainActor
@Observable
final class TrashViewModel {
    enum LoadState: Equatable { case idle, loading, loaded, failed(String) }

    private let repo: DeckRepositoring
    private(set) var state: LoadState = .idle
    private(set) var decks: [Deck] = []
    var actionError: String?

    init(repo: DeckRepositoring) { self.repo = repo }

    func load() async {
        if case .loaded = state {} else { state = .loading }
        do {
            decks = try await repo.listTrashedDecks()
            state = .loaded
        } catch {
            state = .failed(DeckListViewModel.message(for: error))
        }
    }

    func restore(_ deck: Deck) async {
        do {
            _ = try await repo.restoreDeck(id: deck.id)
            await load()
        } catch {
            actionError = DeckListViewModel.message(for: error)
        }
    }
}

#Preview("With trashed decks") {
    let trashed = [
        Deck(id: "t1", owner: "u1", name: "Old Engagement Shoot",
             shootDate: Calendar.current.date(byAdding: .day, value: -40, to: Date()),
             deletedAt: Date()),
        Deck(id: "t2", owner: "u1", name: "Scrapped Concept", deletedAt: Date()),
    ]
    return TrashView(repo: FakeDeckRepository(decks: [], trashed: trashed), ownerId: "u1")
}

#Preview("Empty") {
    TrashView(repo: FakeDeckRepository(decks: [], trashed: []), ownerId: "u1")
}
