import SwiftUI
import PoseDeckCore

/// Read-only shoot-mode screen (DESIGN.md §4.2): an image-prominent presentation
/// of the current card with swipe gestures — right = done, left = skip-to-end,
/// up = expand a detail sheet (full image + notes) — a persistent top-left undo
/// button, a top-center "Card N of M" progress indicator, a skipped badge, an
/// always-available exit, and an end state once every card has been acted on.
///
/// **CI hook:** alongside the swipe physics, hidden accessibility buttons
/// (`shoot.action.done` / `.skip` / `.undo`) call the *same* view-model methods
/// as the gestures, so XCUITest drives the session deterministically without raw
/// swipe physics (the M3 lesson: the simulator must exercise real runtime logic).
struct ShootModeView: View {
    @State private var model: ShootModeViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var dragOffset: CGSize = .zero
    @State private var showDetailSheet = false

    init(_ model: ShootModeViewModel) {
        self._model = State(initialValue: model)
    }

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            content
            topBar
        }
        .navigationBarBackButtonHidden(true)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .task { await model.load() }
        // Tear down any in-flight persist / prefetch work when the screen goes
        // away so unstructured tasks can't outlive it ([FIX-swift-4]).
        .onDisappear { model.cancelPendingWork() }
        .sheet(isPresented: $showDetailSheet) {
            if let card = model.currentCard {
                CardDetailSheet(card: card, imageURL: model.currentImageURL)
            }
        }
        // CI-hook controls overlaid at the bottom: drive the SAME view-model
        // methods as the gestures so UI tests advance the session without
        // simulating swipes. Rendered as a real, hittable (but visually muted)
        // control row so XCUITest can scroll-to-visible + tap them.
        .overlay(alignment: .bottom) { actionHooks }
    }

    @ViewBuilder
    private var content: some View {
        if model.isComplete {
            completeState
        } else if let card = model.currentCard {
            cardView(card)
        } else {
            // No current card and not complete — shouldn't happen, but offer exit.
            ContentUnavailableView("Nothing to shoot", systemImage: "camera")
        }
    }

    // MARK: - Current card

    private func cardView(_ card: Card) -> some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)
            cardImage
                .accessibilityIdentifier("shoot.card-image")
            VStack(spacing: 6) {
                Text(card.title.isEmpty ? "Untitled card" : card.title)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("shoot.card-title")
                let meta = [card.timeSlot, card.subjects]
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " • ")
                if !meta.isEmpty {
                    Text(meta).font(.subheadline).foregroundStyle(.secondary)
                }
                if let direction = card.direction?.trimmingCharacters(in: .whitespacesAndNewlines), !direction.isEmpty {
                    Text(direction)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal)
            Spacer(minLength: 0)
            hintBar
        }
        .padding()
        .offset(dragOffset)
        .gesture(swipeGesture)
    }

    @ViewBuilder
    private var cardImage: some View {
        if let url = model.currentImageURL {
            // Protected token-bearing URL — non-persisting session (SEC-IOS-B).
            ProtectedAsyncImage(url: url) { phase in
                switch phase {
                case .success(let image): image.resizable().scaledToFit()
                case .failure: imagePlaceholder
                default: ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: 420)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        } else {
            imagePlaceholder
                .frame(maxWidth: .infinity, maxHeight: 420)
        }
    }

    private var imagePlaceholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.quaternary)
            Image(systemName: "photo").font(.largeTitle).foregroundStyle(.secondary)
        }
    }

    private var hintBar: some View {
        HStack {
            Label("Skip", systemImage: "arrow.left").foregroundStyle(.secondary)
            Spacer()
            Label("Details", systemImage: "arrow.up").foregroundStyle(.secondary)
            Spacer()
            Label("Done", systemImage: "arrow.right").foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal)
    }

    private var swipeGesture: some Gesture {
        DragGesture()
            .onChanged { value in dragOffset = value.translation }
            .onEnded { value in
                let h = value.translation.width
                let v = value.translation.height
                let threshold: CGFloat = 80
                withAnimation(.easeOut(duration: 0.2)) { dragOffset = .zero }
                if abs(v) > abs(h) && v < -threshold {
                    showDetailSheet = true
                } else if h > threshold {
                    model.done()
                } else if h < -threshold {
                    model.skip()
                }
            }
    }

    // MARK: - Complete state

    private var completeState: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
            Text("Shoot complete")
                .font(.title2.weight(.semibold))
            if model.skippedCount > 0 {
                Text("\(model.skippedCount) card\(model.skippedCount == 1 ? "" : "s") skipped")
                    .foregroundStyle(.secondary)
            }
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
        .accessibilityIdentifier("shoot.complete")
    }

    // MARK: - Top bar (undo / progress / skipped / exit)

    private var topBar: some View {
        VStack {
            HStack(alignment: .top) {
                Button { model.undo() } label: {
                    Image(systemName: "arrow.uturn.backward.circle.fill")
                        .font(.title)
                }
                .disabled(!model.canUndo)
                .accessibilityIdentifier("shoot.undo-button")

                Spacer()

                VStack(spacing: 4) {
                    Text(model.progressText)
                        .font(.headline)
                        .accessibilityIdentifier("shoot.progress")
                    if model.skippedCount > 0 {
                        Text("+\(model.skippedCount) skipped")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("shoot.skipped-count")
                    }
                }

                Spacer()

                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title)
                }
                .accessibilityIdentifier("shoot.exit")
            }
            .padding(.horizontal)
            .padding(.top, 8)
            Spacer()
        }
    }

    // MARK: - CI-hook accessibility buttons (drive the same model methods)

    /// Explicit tap controls for the three actions, mirroring the swipe gestures.
    /// These are a real, fully-interactive accessibility surface (good practice
    /// for users who can't swipe) and double as the deterministic XCUITest hook —
    /// the swipe physics is the primary surface but is hand-verified on-device.
    private var actionHooks: some View {
        HStack(spacing: 24) {
            hookButton("Skip", system: "arrow.left", id: "shoot.action.skip", enabled: !model.isComplete) { model.skip() }
            hookButton("Undo", system: "arrow.uturn.backward", id: "shoot.action.undo", enabled: model.canUndo) { model.undo() }
            hookButton("Done", system: "checkmark", id: "shoot.action.done", enabled: !model.isComplete) { model.done() }
        }
        .padding(.vertical, 8)
        .padding(.bottom, 8)
    }

    private func hookButton(_ title: String, system: String, id: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: system)
                .labelStyle(.iconOnly)
                .font(.title3)
                .frame(width: 48, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .disabled(!enabled)
        .accessibilityLabel(title)
        .accessibilityIdentifier(id)
    }
}

/// Swipe-up detail sheet: the full image and the card's notes. Dismiss by
/// swiping down (system) or tapping the close button.
private struct CardDetailSheet: View {
    let card: Card
    let imageURL: URL?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let imageURL {
                        // Protected token-bearing URL — non-persisting session (SEC-IOS-B).
                        ProtectedAsyncImage(url: imageURL) { phase in
                            if case .success(let image) = phase {
                                image.resizable().scaledToFit()
                            } else {
                                Color.clear.frame(height: 1)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    Text(card.title.isEmpty ? "Untitled card" : card.title)
                        .font(.title3.weight(.semibold))
                    if let direction = card.direction, !direction.isEmpty {
                        labeled("Direction", direction)
                    }
                    if let notes = card.notes, !notes.isEmpty {
                        labeled("Notes", notes)
                    }
                }
                .padding()
            }
            .navigationTitle("Card details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .accessibilityIdentifier("shoot.detail-sheet")
    }

    private func labeled(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.body)
        }
    }
}

#Preview("Shoot") {
    let cards = [
        Card(id: "c1", deck: "d1", position: 1000, title: "Golden hour portrait",
             timeSlot: "16:30", subjects: "Bride & groom", direction: "Backlit, look away"),
        Card(id: "c2", deck: "d1", position: 2000, title: "First look",
             timeSlot: "11:00", subjects: "Couple", notes: "Soft window light"),
        Card(id: "c3", deck: "d1", position: 3000, title: "Family formals", subjects: "Full family"),
    ]
    return NavigationStack {
        ShootModeView(ShootModeViewModel(
            deck: Deck(id: "d1", owner: "u1", name: "Wedding"),
            cards: cards,
            completionRepo: FakeCardCompletionRepository(),
            imageRepo: FakeCardImageRepository(),
            userId: "u1"
        ))
    }
}
