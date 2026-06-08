import SwiftUI
import PhotosUI
import UIKit
import UniformTypeIdentifiers
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
    /// A photo picked before the card exists: compressed bytes held locally with
    /// a preview, uploaded by ``flushStaged(cardId:)`` once the card is created.
    /// This lets the editor offer the image section *during* new-card creation
    /// instead of forcing a "Create first" round-trip — `card_images.card` is a
    /// required relation to a saved card, so we can't upload until the card has
    /// an id, but we can stage the bytes immediately.
    struct StagedImage: Identifiable {
        let id: String
        /// Already-compressed JPEG bytes (compressed at stage time, uploaded as-is).
        let data: Data
        /// In-memory preview for the thumbnail grid.
        let preview: UIImage
    }

    /// The card these images belong to. `nil` while creating a new card (images
    /// are staged); set once the card exists (edit mode, or after first save).
    private(set) var cardId: String?
    private let repository: ImageRepositing
    private let compressor: ImageCompressor
    /// Awaits a just-created card becoming available server-side before staged
    /// images upload onto it (the card create flushes via the outbox, but uploads
    /// hit the server directly). Returns false if it isn't ready (offline/
    /// transient). `nil` in previews/tests with a synchronous fake repo, where the
    /// "card" exists immediately and no drain is needed.
    private let awaitCardReady: (@Sendable (String) async -> Bool)?

    /// Images already persisted on the card, sorted by position.
    private(set) var images: [CardImage] = []
    /// Photos picked before the card exists, awaiting upload on create.
    private(set) var stagedImages: [StagedImage] = []
    /// Resolved (token-carrying) display URLs keyed by image id; populated async.
    private(set) var imageURLs: [String: URL] = [:]
    /// Per-image count of consecutive token re-mints in the current `.failure`
    /// streak (SWIFT-A1). PocketBase mints a fresh `?token=` per `fileURL(for:)`,
    /// so a naive "URL changed" guard never fires on a genuine 404 and the
    /// `.failure -> re-mint -> re-render -> .failure` chain spins forever. We cap
    /// re-mints per image identity via `ThumbnailRefresh.shouldApply`. A fresh
    /// `resolveURLs()` pass clears the streaks.
    private var remintAttempts: [String: Int] = [:]

    /// True while the initial image list loads.
    private(set) var isLoading = false
    /// True while a picked image is compressing/uploading.
    private(set) var isUploading = false
    /// Last user-facing error (load/upload/delete), if any.
    var errorMessage: String?

    var maxImagesPerCard: Int { repository.maxImagesPerCard }
    /// Total images counting toward the cap = persisted + staged (uploaded yet
    /// or not, they all become real images on create).
    var imageCount: Int { images.count + stagedImages.count }
    var atImageLimit: Bool { imageCount >= maxImagesPerCard }
    var remainingSlots: Int { max(0, maxImagesPerCard - imageCount) }

    init(
        cardId: String?,
        repository: ImageRepositing,
        compressor: ImageCompressor = ImageCompressor(),
        awaitCardReady: (@Sendable (String) async -> Bool)? = nil
    ) {
        self.cardId = cardId
        self.repository = repository
        self.compressor = compressor
        self.awaitCardReady = awaitCardReady
    }

    /// Load the card's images and resolve their display URLs. A no-op while the
    /// card doesn't exist yet (new-card creation) — there's nothing to fetch and
    /// staged images live purely in memory until create.
    func load() async {
        guard let cardId else { return }
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
        // A fresh resolve pass ends any prior per-image re-mint streak, so an
        // image that previously hit the genuine-404 cap gets another chance to
        // recover (e.g. restored bytes, or a legitimate later token expiry).
        remintAttempts.removeAll()
    }

    /// Re-mint a single image's display URL after its `AsyncImage` failed to
    /// load — most commonly an expired file token on a long-lived editor
    /// session. Only updates state when the refreshed URL differs, to avoid an
    /// infinite reload loop on a genuine 404 (mirrors the web `handleImageError`).
    func refreshURL(for image: CardImage) async {
        guard let fresh = try? await repository.fileURL(for: image) else { return }
        let current = imageURLs[image.id]
        let attempts = remintAttempts[image.id, default: 0]
        // Reset the streak if the underlying image identity changed.
        let identityChanged = current.map {
            ThumbnailRefresh.identity(of: fresh) != ThumbnailRefresh.identity(of: $0)
        } ?? true
        let effectiveAttempts = identityChanged ? 0 : attempts
        if ThumbnailRefresh.shouldApply(fresh: fresh, current: current, attempts: effectiveAttempts) {
            imageURLs[image.id] = fresh
            remintAttempts[image.id] = effectiveAttempts + 1
        }
    }

    /// Compress and either upload (card exists) or stage (new card, no id yet) a
    /// picked photo, enforcing the per-card cap.
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
            if let cardId {
                // Card exists → upload now. Position continues past staged ids too
                // (defensive: staged should be empty once a card exists).
                let position = nextPosition()
                let uploaded = try await repository.uploadCardImage(
                    cardId: cardId,
                    data: compressed,
                    position: position
                )
                images.append(uploaded)
                images.sort { $0.position < $1.position }
                await resolveURLs()
            } else {
                // New card with no id yet → stage the compressed bytes + a preview;
                // they upload in `flushStaged(cardId:)` when the card is created.
                guard let preview = UIImage(data: compressed) else {
                    errorMessage = "Could not read the selected image."
                    isUploading = false
                    return
                }
                stagedImages.append(StagedImage(id: UUID().uuidString, data: compressed, preview: preview))
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isUploading = false
    }

    /// Next image position = one past the highest persisted OR staged position.
    /// Staged images take provisional positions by their append order so the
    /// final upload order matches what the user saw while picking.
    private func nextPosition() -> Int {
        (images.map(\.position).max() ?? 0) + 1
    }

    /// Upload every staged image against the now-created `cardId`, in pick order,
    /// then clear the staging buffer. Called by the editor right after it creates
    /// the card. Best-effort per image: a failure surfaces an error and leaves
    /// the remaining staged images in place so the user can retry rather than
    /// silently losing photos. Returns true if all staged images uploaded.
    @discardableResult
    func flushStaged(cardId: String) async -> Bool {
        self.cardId = cardId
        guard !stagedImages.isEmpty else { return true }
        isUploading = true
        errorMessage = nil
        defer { isUploading = false }
        // The card was just created via the outbox (optimistic client-id) but its
        // server `create` may not have flushed yet; image uploads hit the server
        // directly, so wait for the card to actually exist server-side first —
        // otherwise every upload 404s. If it never becomes ready (offline), keep
        // the staged photos so the user can retry rather than losing them.
        if let awaitCardReady {
            guard await awaitCardReady(cardId) else {
                errorMessage = "Couldn't reach the server to upload images. Your photos are kept — tap Save to try again."
                return false
            }
        }
        // Snapshot so we can dequeue successes while iterating.
        let pending = stagedImages
        var position = (images.map(\.position).max() ?? 0)
        for staged in pending {
            position += 1
            do {
                let uploaded = try await repository.uploadCardImage(
                    cardId: cardId,
                    data: staged.data,
                    position: position
                )
                images.append(uploaded)
                stagedImages.removeAll { $0.id == staged.id }
            } catch {
                errorMessage = "Some images couldn't be uploaded. Please try again."
                images.sort { $0.position < $1.position }
                await resolveURLs()
                return false
            }
        }
        images.sort { $0.position < $1.position }
        await resolveURLs()
        return true
    }

    /// Remove a staged (not-yet-uploaded) image before the card is created.
    func removeStaged(_ staged: StagedImage) {
        stagedImages.removeAll { $0.id == staged.id }
    }

    /// Handle an image pasted from the system clipboard (item 1). Reuses
    /// ``addImage(data:)`` so the in-flight/cap gate, compressor, and per-card cap
    /// are all enforced exactly as for a picked photo — mirrors the web paste path
    /// which shares the same `useImageUpload` flow. A `PasteButton` only delivers
    /// `supportedContentTypes` matches, so a non-image clipboard never reaches
    /// here (no-op, no toast).
    func handlePasted(data: Data) async {
        await addImage(data: data)
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
                if !model.images.isEmpty || !model.stagedImages.isEmpty {
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
            Text("Images (\(model.imageCount)/\(model.maxImagesPerCard))")
                .font(.headline)
                .accessibilityIdentifier("cardImages.count")
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
            // Staged (not-yet-uploaded) images picked during new-card creation,
            // rendered from their in-memory preview after the persisted ones.
            ForEach(model.stagedImages) { staged in
                stagedThumbnail(for: staged)
            }
        }
    }

    /// A staged image's thumbnail — same square cell as `thumbnail(for:)` but
    /// sourced from the in-memory preview, with a "staged" tint so it reads as
    /// pending until the card is created.
    private func stagedThumbnail(for staged: CardImagesViewModel.StagedImage) -> some View {
        ZStack(alignment: .topTrailing) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay {
                    Image(uiImage: staged.preview)
                        .resizable()
                        .scaledToFill()
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))

            Button {
                model.removeStaged(staged)
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

    private func thumbnail(for image: CardImage) -> some View {
        ZStack(alignment: .topTrailing) {
            // Establish a true square cell that FITS the grid column width, then
            // overlay the image and hard-`.clipped()` it to those bounds. The old
            // `.aspectRatio(1, contentMode: .fill)` on the image container could
            // resolve to the image's full intrinsic size in a flexible grid column
            // (the `.fill` mode + an unconstrained height is ambiguous), and
            // `.clipShape` only clips drawing — not layout — so an oversized cell
            // overflowed into its neighbors and the buttons below (item 1). A clear
            // square spacer with `.fit` can never exceed the proposed width, so the
            // cell is always a square that crops its image. (Mirrors the web grid's
            // `aspect-square overflow-hidden`.)
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay {
                    if let url = model.imageURLs[image.id] {
                        // Protected token-bearing URL — load via the non-persisting
                        // session so private bytes don't land in URLCache.shared (SEC-IOS-B).
                        ProtectedAsyncImage(url: url) { phase in
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

    /// Load the first pasted image provider's bytes and forward them to the model
    /// (item 1). `PasteButton(supportedContentTypes: [.image])` only yields image
    /// providers, so a non-image clipboard delivers nothing here (no-op). The
    /// bytes are normalized to JPEG via `UIImage` so the shared compress/upload
    /// path always receives an encodable image.
    @MainActor
    private static func handlePaste(_ providers: [NSItemProvider], model: CardImagesViewModel) async {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: UIImage.self) }) else { return }
        let image: UIImage? = await withCheckedContinuation { continuation in
            provider.loadObject(ofClass: UIImage.self) { object, _ in
                continuation.resume(returning: object as? UIImage)
            }
        }
        guard let data = image?.jpegData(compressionQuality: 1.0) else { return }
        await model.handlePasted(data: data)
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
            .accessibilityIdentifier("cardImages.add")

            // Clipboard paste (item 1): mirrors the web paste affordance. The
            // system auto-disables this when the clipboard holds no image; we
            // additionally gate on the same cap/in-flight state as the picker so a
            // paste can't bypass the cap or stack on an in-flight upload. Loads
            // the first image provider's bytes and re-encodes JPEG via UIImage so
            // the shared `addImage` compress/upload/cap path handles it.
            PasteButton(supportedContentTypes: [.image]) { providers in
                Task { await CardImagesSection.handlePaste(providers, model: model) }
            }
            .disabled(model.atImageLimit || model.isUploading)
            .buttonStyle(.bordered)
            .accessibilityIdentifier("cardImages.paste")

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
