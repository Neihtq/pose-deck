import SwiftUI
import PoseDeckCore

/// Read-only shoot-mode screen (DESIGN.md §4.2): an image-prominent presentation
/// of the current card with swipe gestures — right = done, left = skip-to-end,
/// up = expand a detail sheet (full image + notes) — a persistent top-left undo
/// button, a top-center "Card N of M" progress indicator, a skipped badge, an
/// always-available exit, and an end state once every card has been acted on.
///
/// **Control bar:** a single bottom control bar (in a `.safeAreaInset`, outside
/// the card's drag transform) carries four real bordered buttons — Skip
/// (`shoot.action.skip`), Undo (`shoot.action.undo`, gated on `canUndo`), Details
/// (`shoot.action.details`, opens the same detail sheet as swipe-up), and Done
/// (`shoot.action.done`) — which call the *same* view-model methods as the
/// gestures, so XCUITest drives the session deterministically without raw swipe
/// physics (the M3 lesson: the simulator must exercise real runtime logic).
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
        // Single bottom control bar (replaces the old in-card hintBar + the
        // overlapping actionHooks overlay). Lives in the safe-area inset so the
        // card lays out *above* it and the buttons never sit on top of the card
        // content. Buttons drive the SAME view-model methods as the gestures.
        .safeAreaInset(edge: .bottom) { controlBar }
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
        }
        .padding()
        .offset(dragOffset)
        // Rotate toward the drag direction (~12° at full throw) and ease the scale
        // down slightly so the card feels physical instead of stiff (item 2).
        .rotationEffect(.degrees(Double(dragOffset.width / 18).clamped(to: -12...12)))
        .scaleEffect(1 - min(abs(dragOffset.width), 160) / 1600)
        .gesture(swipeGesture)
        .id(session.currentCardId)
        // Re-centre the incoming card the instant the session advances. `dragOffset`
        // is parent `@State`, NOT owned by the `.id`-keyed subtree, so the `.id`
        // swap does *not* reset it — after a fly-off it is still at ±700 and would
        // render the next card off-screen (`[GAUNTLET-1]`). This fires on *any*
        // advance (gesture fly-off or button) and resets without animation so the
        // new card snaps to centre. The button path is already at `.zero` here.
        .onChange(of: session.currentCardId) { dragOffset = .zero }
    }

    /// The id the card view is keyed on — the pure session's current card id.
    private var session: ShootSession { model.session }

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

    private var swipeGesture: some Gesture {
        DragGesture()
            .onChanged { value in dragOffset = value.translation }
            .onEnded { value in
                let h = value.translation.width
                let v = value.translation.height
                let threshold: CGFloat = 80
                if abs(v) > abs(h) && v < -threshold {
                    // Swipe up: open details. Spring the card back to rest.
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { dragOffset = .zero }
                    showDetailSheet = true
                } else if h > threshold {
                    flyOff(toLeading: false) { model.done() }
                } else if h < -threshold {
                    flyOff(toLeading: true) { model.skip() }
                } else {
                    // Under threshold: spring back to centre.
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { dragOffset = .zero }
                }
            }
    }

    /// Fly the current card off-screen in the swipe direction, then advance the
    /// session. We run the mutation on the animation's completion so the departing
    /// frame finishes before the swap; the `.onChange(of: currentCardId)` re-centres
    /// the incoming card. The button path calls `advance()` directly with
    /// `dragOffset == .zero`, so it advances with zero dependence on animation.
    ///
    /// `[GAUNTLET-2]`: the completion captures the card id this fly-off began for
    /// and no-ops if the session has *already* advanced past it — otherwise a
    /// Skip/Done button tap during the 0.22s animation would advance once
    /// immediately and this stale completion would advance *again*, silently
    /// consuming (and persisting a spurious completion for) a never-shown card.
    private func flyOff(toLeading: Bool, _ advance: @escaping () -> Void) {
        let startCardId = session.currentCardId
        let offX: CGFloat = toLeading ? -700 : 700
        withAnimation(.easeIn(duration: 0.22)) {
            dragOffset = CGSize(width: offX, height: 0)
        } completion: {
            guard session.currentCardId == startCardId else { return }
            advance()
        }
    }

    // MARK: - Complete state

    private var completeState: some View {
        // NOTE: do not put `shoot.complete` on the enclosing VStack — making the
        // container an accessibility element merges its children and hides the
        // inner button ids (`shoot.reshoot`) from XCUITest. Keep the marker id on
        // the title text so the buttons stay independently addressable.
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
            Text("Shoot complete")
                .font(.title2.weight(.semibold))
                .accessibilityIdentifier("shoot.complete")
            if model.skippedCount > 0 {
                Text("\(model.skippedCount) card\(model.skippedCount == 1 ? "" : "s") skipped")
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 12) {
                Button("Shoot again") { Task { await model.reshoot() } }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("shoot.reshoot")
                Button("Done") { dismiss() }
                    .buttonStyle(.bordered)
            }
        }
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

    // MARK: - Control bar (single bottom action row)

    /// The single bottom control bar (replaces both the old in-card `hintBar` and
    /// the overlapping `actionHooks` overlay — items 5 + 6). Four real bordered
    /// buttons that drive the same view-model methods as the gestures: Skip, Undo
    /// (gated on `canUndo`; `[C1]` its id `shoot.action.undo` is the XCUITest tap
    /// target and MUST survive), Details (opens the SAME `$showDetailSheet` as the
    /// swipe-up), and Done. Hidden in the complete state, where the reshoot/exit
    /// buttons take over. Lives in the safe-area inset, outside the card's drag
    /// transform, so it never overlaps the card content.
    @ViewBuilder
    private var controlBar: some View {
        if !model.isComplete {
            HStack(spacing: 16) {
                barButton("Skip", system: "arrow.left", id: "shoot.action.skip", enabled: true) {
                    // Button path: advance immediately with zero dependence on the
                    // fly-off animation (`[M-flyoff]`); the `.id` swap keeps the
                    // next card at rest.
                    model.skip()
                }
                barButton("Undo", system: "arrow.uturn.backward", id: "shoot.action.undo", enabled: model.canUndo) {
                    model.undo()
                }
                barButton("Details", system: "arrow.up", id: "shoot.action.details", enabled: true) {
                    showDetailSheet = true
                }
                barButton("Done", system: "checkmark", id: "shoot.action.done", enabled: true) {
                    model.done()
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(.bar)
        }
    }

    private func barButton(_ title: String, system: String, id: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: system)
                .font(.body)
                .frame(maxWidth: .infinity, minHeight: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .disabled(!enabled)
        .accessibilityLabel(title)
        .accessibilityIdentifier(id)
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
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
