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
    @State private var showOverviewSheet = false

    init(_ model: ShootModeViewModel) {
        self._model = State(initialValue: model)
    }

    var body: some View {
        ZStack {
            // Grouped background so the elevated card face (item 2) reads as a
            // card sitting on a surface. Semantic color → adapts to theme (item 3).
            Color(.systemGroupedBackground).ignoresSafeArea()
            content
            topBar
        }
        .navigationBarBackButtonHidden(true)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        // Re-centre the card whenever the shoot transitions into OR out of the
        // complete state. `dragOffset` is parent `@State`; when the final card
        // flies off (to ±700) and the session completes, `cardView` leaves the
        // tree, so *its* `.onChange(of: currentCardId)` can't re-centre. Without
        // this, "Shoot again" re-enters `cardView` with the stale ±700 offset and
        // renders card 1 off-screen / blank until the next advance snaps it back
        // (`[FIX-reshoot-blank]`). This modifier lives on the always-present ZStack
        // so it fires across the complete↔active boundary in both directions.
        .onChange(of: model.isComplete) { dragOffset = .zero }
        .task { await model.load() }
        // Tear down any in-flight persist / prefetch work when the screen goes
        // away so unstructured tasks can't outlive it ([FIX-swift-4]).
        .onDisappear { model.cancelPendingWork() }
        .sheet(isPresented: $showDetailSheet) {
            if let card = model.currentCard {
                // The detail sheet shows ALL of the card's reference photos in a
                // horizontal carousel (item 6), not just the first. It resolves
                // the full set on appear; until then it falls back to the single
                // prefetched first image so it's never blank.
                CardDetailSheet(
                    card: card,
                    imageURLs: model.currentCardImageURLs,
                    loadAllImages: { await model.loadAllImagesForCurrentCard() }
                )
            }
        }
        // Single bottom control bar (replaces the old in-card hintBar + the
        // overlapping actionHooks overlay). Lives in the safe-area inset so the
        // card lays out *above* it and the buttons never sit on top of the card
        // content. Buttons drive the SAME view-model methods as the gestures.
        .safeAreaInset(edge: .bottom) { controlBar }
        // Upcoming-cards overview (item 5): see the shoot order and reorder it.
        .sheet(isPresented: $showOverviewSheet) {
            ShootOverviewSheet(model: model)
        }
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
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            // The card "face": a real card surface (elevated fill, continuous
            // rounded corners, hairline stroke, soft shadow) so shoot mode reads
            // as a physical deck of cards instead of a bare list of fields
            // (item 2). The drag transform is applied to this whole surface below.
            VStack(spacing: 16) {
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
            }
            .padding(24)
            .frame(maxWidth: .infinity)
            .background(cardSurface)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
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

    /// The card-face background: an elevated surface with continuous rounded
    /// corners, a hairline border, and a soft shadow so the shoot card looks
    /// like a real card (item 2). Uses semantic system colors so it adapts to
    /// the active light/dark theme (item 3).
    private var cardSurface: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(Color(.secondarySystemGroupedBackground))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.18), radius: 18, x: 0, y: 10)
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

                // Tapping the progress opens the upcoming-cards overview (item 5);
                // it doubles as the visible "shoot order" affordance. Kept as a
                // plain VStack of Texts (NOT a Button/Label) so `shoot.progress`
                // keeps its exact "Card N of M" accessibility label the XCUITest
                // asserts on — a Button/Label subtree would merge or shadow it.
                // Tappability is added via `.onTapGesture` + an explicit button
                // trait for VoiceOver, leaving the accessibility tree unchanged.
                VStack(spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "list.bullet")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text(model.progressText)
                            .font(.headline)
                            .accessibilityIdentifier("shoot.progress")
                    }
                    if model.skippedCount > 0 {
                        Text("+\(model.skippedCount) skipped")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("shoot.skipped-count")
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { if !model.isComplete { showOverviewSheet = true } }
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Shows and reorders upcoming cards")

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

/// Swipe-up detail sheet: a horizontal carousel of ALL the card's reference
/// photos (item 6) plus the card's notes. Dismiss by swiping down (system) or
/// tapping the close button.
private struct CardDetailSheet: View {
    let card: Card
    /// All resolved image URLs in position order. May start with just the
    /// prefetched first image and grow once `loadAllImages` resolves the rest.
    let imageURLs: [URL]
    /// Resolves the full image set for the current card (best-effort, idempotent).
    let loadAllImages: () async -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Full-bleed image carousel (item 2 follow-up: detail photos
                    // were too small). The images sit edge-to-edge at the top of
                    // the sheet; only the text below keeps the readable inset.
                    imageCarousel
                    VStack(alignment: .leading, spacing: 16) {
                        Text(card.title.isEmpty ? "Untitled card" : card.title)
                            .font(.title3.weight(.semibold))
                        if let direction = card.direction, !direction.isEmpty {
                            labeled("Direction", direction)
                        }
                        if let notes = card.notes, !notes.isEmpty {
                            labeled("Notes", notes)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom)
                }
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
        // Resolve the rest of the card's images once the sheet is on screen.
        .task { await loadAllImages() }
    }

    /// Horizontally scrollable, paged carousel of the card's images. With a
    /// single image it shows just that image (no paging affordance); with
    /// several it pages between them and shows an "n of m" counter. Each image is
    /// loaded through the non-persisting session (SEC-IOS-B).
    @ViewBuilder
    private var imageCarousel: some View {
        if imageURLs.isEmpty {
            EmptyView()
        } else if imageURLs.count == 1 {
            carouselImage(imageURLs[0])
                .frame(maxWidth: .infinity)
                .frame(height: carouselHeight)
                .accessibilityIdentifier("shoot.detail-carousel")
        } else {
            VStack(spacing: 8) {
                TabView {
                    ForEach(Array(imageURLs.enumerated()), id: \.offset) { _, url in
                        carouselImage(url)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .always))
                .frame(height: carouselHeight)
                .accessibilityIdentifier("shoot.detail-carousel")
                Text("\(imageURLs.count) photos — swipe to browse")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Detail-sheet image height: ~55% of the screen so reference photos are
    /// shown large (the previous fixed 360pt felt cramped). Clamped so it stays
    /// reasonable on very short/tall devices.
    private var carouselHeight: CGFloat {
        let screen = UIScreen.main.bounds.height
        return min(max(screen * 0.55, 360), 640)
    }

    private func carouselImage(_ url: URL) -> some View {
        ProtectedAsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFit()
            case .failure:
                Color.clear.frame(height: 1)
            default:
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
