import SwiftUI
import PoseDeckCore

/// In-shoot overview (item 5): a sheet listing the upcoming (not-yet-done) cards
/// in shoot order — current card first — that the photographer can **reorder**
/// to change what they shoot next.
///
/// Reorder is **session-scoped and ephemeral** by design: the shoot working
/// order is per-device and never synced (see ``ShootSession`` docs / `[FIX-M6]`),
/// so dragging a row here changes only the live session. Durable, synced
/// reordering lives in the deck-prep screen. The pure session validates the new
/// order (a non-permutation is a no-op), so this UI can never corrupt the
/// session even if it drifts from the model mid-drag.
struct ShootOverviewSheet: View {
    @Bindable var model: ShootModeViewModel
    @Environment(\.dismiss) private var dismiss

    /// EditMode is on by default so the drag handles are always visible — the
    /// whole point of this sheet is reordering, so we don't make the user hunt
    /// for an Edit button first.
    @State private var editMode: EditMode = .active

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(model.upcomingCards) { card in
                        row(for: card)
                    }
                    .onMove(perform: move)
                } header: {
                    Text("Up next — drag to reorder")
                } footer: {
                    Text("Reordering changes this shoot only. Your deck's saved order isn't affected.")
                }
            }
            .environment(\.editMode, $editMode)
            .navigationTitle("Shoot order")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("shoot.overview.done")
                }
            }
            .overlay {
                if model.upcomingCards.isEmpty {
                    ContentUnavailableView(
                        "Nothing left to shoot",
                        systemImage: "checkmark.circle",
                        description: Text("Every card has been shot or skipped.")
                    )
                }
            }
            .task { await model.prefetchOverviewThumbnails() }
        }
        .accessibilityIdentifier("shoot.overview-sheet")
    }

    private func row(for card: Card) -> some View {
        HStack(spacing: 12) {
            thumbnail(for: card)
            VStack(alignment: .leading, spacing: 2) {
                Text(card.title.isEmpty ? "Untitled card" : card.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                let meta = [card.timeSlot, card.subjects]
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " • ")
                if !meta.isEmpty {
                    Text(meta)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if card.id == model.session.currentCardId {
                Text("Current")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.tint.opacity(0.15), in: Capsule())
            }
        }
        .accessibilityIdentifier("shoot.overview.row")
    }

    @ViewBuilder
    private func thumbnail(for card: Card) -> some View {
        Group {
            if let url = model.thumbnailURL(for: card.id) {
                // Protected token-bearing URL — non-persisting session (SEC-IOS-B).
                ProtectedAsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: 52, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var placeholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quaternary)
            Image(systemName: "photo").foregroundStyle(.secondary)
        }
    }

    /// Translate a SwiftUI list move into a reorder of the upcoming-card ids and
    /// hand it to the model, which routes it through the pure session's
    /// permutation-guarded `reorderUpcoming`.
    private func move(from source: IndexSet, to destination: Int) {
        var ids = model.upcomingCards.map(\.id)
        ids.move(fromOffsets: source, toOffset: destination)
        model.reorderUpcoming(ids)
    }
}
