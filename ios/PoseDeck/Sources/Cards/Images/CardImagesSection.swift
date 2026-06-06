import SwiftUI
import PhotosUI
import PoseDeckCore

/// View model backing ``CardImagesSection``.
///
/// Owns the list of a card's images, resolves protected token-carrying display
/// URLs (mirrors the web `imageDisplayUrl` flow), and runs the picked-photo →
/// ``ImageCompressor`` → ``ImageRepositing/uploadCardImage`` pipeline. The 5-image
/// cap is enforced both here (defensive) and in the UI.
///
/// Driven by the ``ImageRepositing`` protocol so previews/tests can inject a fake
/// without touching the network.
@MainActor
@Observable
final class CardImagesViewModel {
    /// The card these images belong to. Images attach to a saved card record, so
    /// the section is only usable once the card exists.
    let cardId: String
    private let repository: ImageRepositing
    private let compressor: ImageCompressor

    /// Images currently on the card, sorted by position.
    private(set) var images: [CardImage] = []
    /// Resolved (token-carrying) display URLs keyed by image id; populated async.
    private(set) var imageURLs: [String: URL] = [:]

    /// True while the initial image list loads.
    private(set) var isLoading = false
    /// True while a picked image is compressing/uploading.
    private(set) var isUploading = false
    /// Last user-facing error (load/upload/delete), if any.
    var errorMessage: String?

    var maxImagesPerCard: Int { repository.maxImagesPerCard }
    var atImageLimit: Bool { images.count >= maxImagesPerCard }
    var remainingSlots: Int { max(0, maxImagesPerCard - images.count) }

    init(cardId: String, repository: ImageRepositing, compressor: ImageCompressor = ImageCompressor()) {
        self.cardId = cardId
        self.repository = repository
        self.compressor = compressor
    }

    /// Load the card's images and resolve their display URLs.
    func load() async {
        isLoading = true
        errorMessage = nil
        do {
            images = try await repository.listCardImages(cardId: cardId)
            await resolveURLs()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    /// Resolve a token-carrying display URL for each image. `card_images` files
    /// are protected, so each URL is minted async with a short-lived `?token=`.
    private func resolveURLs() async {
        var resolved: [String: URL] = [:]
        for image in images {
            if let url = try? await repository.fileURL(for: image) {
                resolved[image.id] = url
            }
        }
        imageURLs = resolved
    }

    /// Re-mint a single image's display URL after its `AsyncImage` failed to
    /// load — most commonly an expired file token on a long-lived editor
    /// session. Only updates state when the refreshed URL differs, to avoid an
    /// infinite reload loop on a genuine 404 (mirrors the web `handleImageError`).
    func refreshURL(for image: CardImage) async {
        guard let fresh = try? await repository.fileURL(for: image) else { return }
        if imageURLs[image.id] != fresh {
            imageURLs[image.id] = fresh
        }
    }

    /// Compress and upload a picked photo, enforcing the per-card cap.
    func addImage(data: Data) async {
        // Synchronous gate run before the upload suspends. An upload suspends at
        // compress/upload before `images.append` lands, so `atImageLimit` (a
        // stale count-based check) cannot see in-flight work. Without an
        // in-flight guard, a concurrent paste + file-pick could both pass the
        // check-then-act cap check and transiently exceed the cap client-side.
        // `addImage` is @MainActor and there is no `await` between this check and
        // `isUploading = true`, so the pair is atomic and closes the window
        // (mirrors the web `inFlight` ref in useImageUpload.ts).
        switch ImageUploadGate.evaluate(isUploading: isUploading, atImageLimit: atImageLimit) {
        case .busy:
            errorMessage = "Please wait for the current upload to finish."
            return
        case .atLimit:
            errorMessage = "A card can have at most \(maxImagesPerCard) images."
            return
        case .allowed:
            break
        }
        isUploading = true
        errorMessage = nil
        do {
            let compressed = try compressor.compress(data)
            let position = (images.map(\.position).max() ?? 0) + 1
            let uploaded = try await repository.uploadCardImage(
                cardId: cardId,
                data: compressed,
                position: position
            )
            images.append(uploaded)
            images.sort { $0.position < $1.position }
            await resolveURLs()
        } catch {
            errorMessage = error.localizedDescription
        }
        isUploading = false
    }

    /// Handle a `PhotosPickerItem` selection: load its bytes then upload.
    func handlePicked(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                errorMessage = "Could not read the selected image."
                return
            }
            await addImage(data: data)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Delete an image (card_images has no soft-delete).
    func deleteImage(_ image: CardImage) async {
        errorMessage = nil
        do {
            try await repository.deleteCardImage(id: image.id)
            images.removeAll { $0.id == image.id }
            imageURLs[image.id] = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Card image gallery: 0–5 thumbnails with per-image delete and a PhotosUI
/// picker that compresses and uploads (DESIGN.md §3.1, ARCHITECTURE.md §5).
///
/// Images attach to a saved card record, so this section is only shown once the
/// card exists (the editor gates it behind first save — mirrors the web flow).
struct CardImagesSection: View {
    @State private var model: CardImagesViewModel
    @State private var pickerItem: PhotosPickerItem?

    init(model: CardImagesViewModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if model.isLoading {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Loading images…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                if !model.images.isEmpty {
                    thumbnailGrid
                }
                addButton
                if let message = model.errorMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .task { await model.load() }
        .onChange(of: pickerItem) { _, newItem in
            guard newItem != nil else { return }
            Task {
                await model.handlePicked(newItem)
                pickerItem = nil
            }
        }
    }

    private var header: some View {
        HStack {
            Text("Images (\(model.images.count)/\(model.maxImagesPerCard))")
                .font(.headline)
            Spacer()
            if model.atImageLimit {
                Text("Max reached")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.secondary.opacity(0.2), in: Capsule())
            }
        }
    }

    private var thumbnailGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ForEach(model.images) { image in
                thumbnail(for: image)
            }
        }
    }

    private func thumbnail(for image: CardImage) -> some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let url = model.imageURLs[image.id] {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let img):
                            img.resizable().scaledToFill()
                        case .failure:
                            Color.secondary.opacity(0.15)
                                .overlay(Image(systemName: "exclamationmark.triangle"))
                                .task { await model.refreshURL(for: image) }
                        case .empty:
                            Color.secondary.opacity(0.1).overlay(ProgressView())
                        @unknown default:
                            Color.secondary.opacity(0.1)
                        }
                    }
                } else {
                    Color.secondary.opacity(0.1).overlay(ProgressView())
                }
            }
            .aspectRatio(1, contentMode: .fill)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Button {
                Task { await model.deleteImage(image) }
            } label: {
                Image(systemName: "trash.fill")
                    .font(.caption)
                    .padding(6)
                    .background(.thinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .padding(4)
            .accessibilityLabel("Remove image")
        }
    }

    private var addButton: some View {
        HStack(spacing: 12) {
            PhotosPicker(
                selection: $pickerItem,
                matching: .images,
                photoLibrary: .shared()
            ) {
                Label("Add image", systemImage: "photo.badge.plus")
            }
            .disabled(model.atImageLimit || model.isUploading)
            .buttonStyle(.bordered)

            if model.isUploading {
                ProgressView()
            } else if !model.atImageLimit {
                Text("\(model.remainingSlots) slot\(model.remainingSlots == 1 ? "" : "s") left")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Previews

/// In-memory ``ImageRepositing`` fake for previews (no network).
private final class PreviewImageRepository: ImageRepositing, @unchecked Sendable {
    let maxImagesPerCard: Int
    private var stored: [CardImage]

    init(maxImagesPerCard: Int = 5, images: [CardImage] = []) {
        self.maxImagesPerCard = maxImagesPerCard
        self.stored = images
    }

    func uploadCardImage(cardId: String, data: Data, position: Int) async throws -> CardImage {
        let image = CardImage(id: UUID().uuidString, card: cardId, position: position, file: "image.jpg")
        stored.append(image)
        return image
    }

    func listCardImages(cardId: String) async throws -> [CardImage] {
        stored.filter { $0.card == cardId }.sorted { $0.position < $1.position }
    }

    func deleteCardImage(id: String) async throws {
        stored.removeAll { $0.id == id }
    }

    func fileURL(for image: CardImage) async throws -> URL {
        URL(string: "https://picsum.photos/seed/\(image.id)/300")!
    }
}

#Preview("With images") {
    let repo = PreviewImageRepository(images: [
        CardImage(id: "img1", card: "card1", position: 1, file: "a.jpg"),
        CardImage(id: "img2", card: "card1", position: 2, file: "b.jpg"),
    ])
    return ScrollView {
        CardImagesSection(model: CardImagesViewModel(cardId: "card1", repository: repo))
            .padding()
    }
}

#Preview("Empty") {
    CardImagesSection(model: CardImagesViewModel(cardId: "card1", repository: PreviewImageRepository()))
        .padding()
}
