import Foundation

/// Errors surfaced by ``ImageRepository``.
public enum ImageRepositoryError: Error, Sendable, Equatable {
    /// Adding an image would exceed ``ImageRepository/maxImagesPerCard``.
    case tooManyImages(cardId: String)
    /// A file URL could not be constructed for the given record/filename.
    case invalidFileURL
}

/// The `card_images` operations the app needs (ARCHITECTURE.md §3.4, §5).
///
/// A protocol so views/tests can use a fake without the network.
public protocol ImageRepositing: Sendable {
    /// Maximum images allowed on a single card (DESIGN.md prep rules).
    var maxImagesPerCard: Int { get }

    /// Upload `data` (already compressed JPEG) as a new `card_images` record for
    /// `cardId` at `position`. Enforces the per-card cap, throwing
    /// ``ImageRepositoryError/tooManyImages(cardId:)`` if the card is full.
    @discardableResult
    func uploadCardImage(cardId: String, data: Data, position: Int) async throws -> CardImage

    /// List a card's images sorted by `position` (ascending).
    func listCardImages(cardId: String) async throws -> [CardImage]

    /// Delete a `card_images` record by id (images have no soft-delete).
    func deleteCardImage(id: String) async throws

    /// Build a display URL for a stored image file, carrying a freshly minted
    /// short-lived `?token=` because `card_images` is a protected collection.
    func fileURL(for image: CardImage) async throws -> URL
}

/// `card_images` repository backed by ``APIClient`` (ARCHITECTURE.md §3.4, §5).
///
/// Uploads via multipart, lists/deletes via the generic CRUD surface, and builds
/// protected file URLs with a minted file token (mirrors the web fix:
/// `GET /api/files/...` for `card_images` requires `?token=`, not the
/// `Authorization` header).
public struct ImageRepository: ImageRepositing {
    /// PocketBase collection name for card images.
    public static let collection = "card_images"

    public let maxImagesPerCard: Int
    private let client: APIClient

    public init(client: APIClient, maxImagesPerCard: Int = 5) {
        self.client = client
        self.maxImagesPerCard = maxImagesPerCard
    }

    /// Pure cap check: throws ``ImageRepositoryError/tooManyImages(cardId:)`` if
    /// adding one image to a card that already has `existingCount` would exceed
    /// `max`. Extracted so the cap rule is unit-testable without the network.
    public static func checkCanAddImage(existingCount: Int, max: Int, cardId: String) throws {
        guard existingCount < max else {
            throw ImageRepositoryError.tooManyImages(cardId: cardId)
        }
    }

    @discardableResult
    public func uploadCardImage(cardId: String, data: Data, position: Int) async throws -> CardImage {
        // Enforce the per-card cap by counting existing (non-deleted) images
        // first — mirrors the web behaviour. card_images has no soft-delete.
        let existing = try await listCardImages(cardId: cardId)
        try Self.checkCanAddImage(
            existingCount: existing.count,
            max: maxImagesPerCard,
            cardId: cardId
        )

        let fields: [APIClient.MultipartField] = [
            .file(name: "file", filename: "image.jpg", mimeType: "image/jpeg", data: data),
            .text(name: "card", value: cardId),
            .text(name: "position", value: String(position)),
        ]
        return try await client.createMultipart(collection: Self.collection, fields: fields)
    }

    public func listCardImages(cardId: String) async throws -> [CardImage] {
        // PocketBase filter values must be quoted/escaped; ids are server-issued
        // alphanumerics so a simple quoted equality is safe here.
        let filter = "card = \"\(cardId)\""
        let response: ListResponse<CardImage> = try await client.list(
            collection: Self.collection,
            page: 1,
            perPage: maxImagesPerCard,
            filter: filter,
            sort: "position"
        )
        return response.items.sorted { $0.position < $1.position }
    }

    public func deleteCardImage(id: String) async throws {
        try await client.delete(collection: Self.collection, id: id)
    }

    public func fileURL(for image: CardImage) async throws -> URL {
        guard let filename = image.file, !filename.isEmpty else {
            throw ImageRepositoryError.invalidFileURL
        }
        let token = try await client.fileToken()
        guard let url = client.fileURL(
            collection: Self.collection,
            recordId: image.id,
            filename: filename,
            token: token
        ) else {
            throw ImageRepositoryError.invalidFileURL
        }
        return url
    }
}
