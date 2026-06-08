import SwiftUI
import PoseDeckCore

/// View model backing ``CardEditorView`` (DESIGN.md §3.1).
///
/// Handles create vs. edit mode, the title cap (60 chars — DESIGN wins over the
/// DB's 200-char headroom), and the save/delete flows over ``CardRepository``.
/// In create mode, saving creates the card and transitions to edit mode so
/// images can be attached (they need a card id — mirrors the web flow).
@MainActor
@Observable
final class CardEditorViewModel {
    /// Product cap for card titles (DESIGN.md §3.1: ≤60). The DB allows 200 as
    /// headroom; the product limit governs the UI.
    static let titleMax = CardRepository.titleMaxLength

    let deckId: String
    /// Set once the card exists (edit mode, or after first save in create mode).
    private(set) var cardId: String?

    private let repository: any CardRepositoring

    // Form fields
    var title = ""
    var timeSlot = ""
    var subjects = ""
    var direction = ""
    var notes = ""

    private(set) var isLoading = false
    private(set) var isSaving = false
    private(set) var isDeleting = false
    var errorMessage: String?

    /// True once the card has been saved at least once — gates the image section.
    var isEditMode: Bool { cardId != nil }
    var heading: String { isEditMode ? "Edit card" : "New card" }

    private var titleTrimmed: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    var titleTooLong: Bool { title.count > Self.titleMax }
    var canSave: Bool { !titleTrimmed.isEmpty && !titleTooLong && !isSaving }

    init(deckId: String, cardId: String? = nil, repository: any CardRepositoring) {
        self.deckId = deckId
        self.cardId = cardId
        self.repository = repository
    }

    /// Load the existing card in edit mode. Scoped to non-deleted so a trashed
    /// card reads as not-found (mirrors the web `deleted_at = ""` guard).
    func load() async {
        guard let cardId else { return }
        isLoading = true
        errorMessage = nil
        do {
            let cards = try await repository.listCards(deckId: deckId)
            guard let card = cards.first(where: { $0.id == cardId }) else {
                errorMessage = "This card is no longer available."
                isLoading = false
                return
            }
            title = card.title
            timeSlot = card.timeSlot ?? ""
            subjects = card.subjects ?? ""
            direction = card.direction ?? ""
            notes = card.notes ?? ""
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    /// Save the card. In edit mode, updates and returns `.saved`. In create
    /// mode, creates the card, transitions this VM into edit mode (so images can
    /// attach), and returns `.created` (the editor stays open).
    enum SaveOutcome { case created, saved, failed }

    @discardableResult
    func save() async -> SaveOutcome {
        guard canSave else { return .failed }
        isSaving = true
        errorMessage = nil
        let trimmed = titleTrimmed
        defer { isSaving = false }
        do {
            if let cardId {
                let partial = CardRepository.PartialCardFields(
                    title: trimmed,
                    timeSlot: timeSlot,
                    subjects: subjects,
                    direction: direction,
                    notes: notes
                )
                _ = try await repository.updateCard(id: cardId, fields: partial)
                return .saved
            } else {
                let fields = CardRepository.CardFields(
                    title: trimmed,
                    timeSlot: timeSlot,
                    subjects: subjects,
                    direction: direction,
                    notes: notes
                )
                let created = try await repository.createCard(deckId: deckId, fields: fields)
                cardId = created.id
                return .created
            }
        } catch {
            errorMessage = error.localizedDescription
            return .failed
        }
    }

    /// Soft-delete the card (never hard-delete). Returns true on success.
    func delete() async -> Bool {
        guard let cardId else { return false }
        isDeleting = true
        errorMessage = nil
        defer { isDeleting = false }
        do {
            _ = try await repository.softDeleteCard(id: cardId)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}

/// Create/edit a single card (DESIGN.md §3.1).
///
/// Fields: Title (required, ≤60 with a live counter), Time / slot, Subjects,
/// Direction (single-line), Notes (multi-line). In create mode the image section
/// is gated behind first save (images need a card id). Delete soft-deletes.
///
/// Navigation: the editor calls `onClose` after a successful save (edit mode) or
/// delete, so the host (deck detail) can pop the stack. In create mode, a
/// successful save keeps the editor open in edit mode to let the user attach
/// images, then Close/Save returns. The integration agent owns the
/// `NavigationStack` push and wiring `onClose`.
struct CardEditorView: View {
    @State private var model: CardEditorViewModel
    /// The image section's model — created up front (with the optional cardId, so
    /// it stages photos during new-card creation) and reused for the editor's
    /// lifetime, so picks survive the create transition.
    @State private var imagesModel: CardImagesViewModel
    /// Called when the editor is finished (saved in edit mode, or deleted).
    private let onClose: () -> Void

    @State private var showDeleteConfirm = false

    init(
        model: CardEditorViewModel,
        makeImagesModel: (String?) -> CardImagesViewModel,
        onClose: @escaping () -> Void
    ) {
        _model = State(initialValue: model)
        // Seed the image model with the current cardId (nil in create mode → it
        // stages picks until the card is created and `flushStaged` runs).
        _imagesModel = State(initialValue: makeImagesModel(model.cardId))
        self.onClose = onClose
    }

    var body: some View {
        Form {
            if model.isLoading {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Loading card…").foregroundStyle(.secondary)
                }
            } else {
                fieldsSection
                notesSection
                imagesSection
                if model.isEditMode {
                    deleteSection
                }
            }
            if let message = model.errorMessage {
                Section {
                    Text(message).font(.footnote).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(model.heading)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(saveButtonTitle) {
                    Task { await handleSave() }
                }
                .disabled(!model.canSave)
                .accessibilityIdentifier("cardEditor.save")
            }
        }
        .task { await model.load() }
        .confirmationDialog(
            "Delete this card?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task {
                    if await model.delete() { onClose() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The card will be moved out of the deck. This can be undone from the deck.")
        }
    }

    private var saveButtonTitle: String {
        model.isEditMode ? "Save" : "Create"
    }

    private func handleSave() async {
        let outcome = await model.save()
        switch outcome {
        case .saved:
            // Edit-mode save returns to the deck.
            onClose()
        case .created:
            // Create-mode: the card now has an id. Upload any photos staged while
            // creating, then return to the deck. If an upload fails, stay open so
            // the user sees the error and can retry rather than silently losing
            // photos (the card itself is already created).
            guard let newId = model.cardId else { onClose(); return }
            let allUploaded = await imagesModel.flushStaged(cardId: newId)
            if allUploaded {
                onClose()
            }
        case .failed:
            break
        }
    }

    private var fieldsSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                TextField("Title", text: $model.title)
                    .textInputAutocapitalization(.sentences)
                    .accessibilityIdentifier("cardEditor.title")
                HStack {
                    if model.titleTooLong {
                        Text("Title must be \(CardEditorViewModel.titleMax) characters or fewer.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    Spacer()
                    Text("\(model.title.count)/\(CardEditorViewModel.titleMax)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(model.titleTooLong ? .red : .secondary)
                        .accessibilityIdentifier("cardEditor.titleCounter")
                }
            }
            TextField("Time / slot", text: $model.timeSlot)
                .accessibilityIdentifier("cardEditor.timeSlot")
            TextField("Subjects / names", text: $model.subjects)
                .accessibilityIdentifier("cardEditor.subjects")
            TextField("Direction", text: $model.direction)
                .accessibilityIdentifier("cardEditor.direction")
        } header: {
            Text("Card")
        } footer: {
            Text("Title is required.")
        }
    }

    @ViewBuilder
    private var imagesSection: some View {
        Section("Images") {
            CardImagesSection(model: imagesModel)
                .padding(.vertical, 4)
            if !model.isEditMode {
                Text("Photos are added when you tap Create.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var notesSection: some View {
        Section("Notes") {
            TextEditor(text: $model.notes)
                .frame(minHeight: 120)
        }
    }

    private var deleteSection: some View {
        Section {
            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                Label("Delete card", systemImage: "trash")
            }
            .disabled(model.isDeleting)
        }
    }
}

// MARK: - Previews

private func previewClient() -> APIClient {
    APIClient(baseURL: URL(string: "http://localhost:8090")!)
}

private final class PreviewImagesRepo: ImageRepositing, @unchecked Sendable {
    let maxImagesPerCard = 5
    func uploadCardImage(cardId: String, data: Data, position: Int) async throws -> CardImage {
        CardImage(id: UUID().uuidString, card: cardId, position: position, file: "image.jpg")
    }
    func listCardImages(cardId: String) async throws -> [CardImage] { [] }
    func deleteCardImage(id: String) async throws {}
    func fileURL(for image: CardImage) async throws -> URL {
        URL(string: "https://picsum.photos/seed/\(image.id)/300")!
    }
}

#Preview("Create") {
    let repo = CardRepository(client: previewClient())
    let imagesRepo = PreviewImagesRepo()
    return NavigationStack {
        CardEditorView(
            model: CardEditorViewModel(deckId: "deck1", repository: repo),
            makeImagesModel: { CardImagesViewModel(cardId: $0, repository: imagesRepo) },
            onClose: {}
        )
    }
}

#Preview("Edit") {
    let repo = CardRepository(client: previewClient())
    let imagesRepo = PreviewImagesRepo()
    let vm = CardEditorViewModel(deckId: "deck1", cardId: "card1", repository: repo)
    vm.title = "Bride & groom first look"
    vm.timeSlot = "16:30"
    return NavigationStack {
        CardEditorView(
            model: vm,
            makeImagesModel: { CardImagesViewModel(cardId: $0, repository: imagesRepo) },
            onClose: {}
        )
    }
}
