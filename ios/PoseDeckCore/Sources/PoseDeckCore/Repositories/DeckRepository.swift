import Foundation

/// Data-access layer for the `decks` collection (ARCHITECTURE.md §3.2).
///
/// Wraps ``APIClient``'s generic CRUD. Mirrors the web `deckApi.ts` reference.
///
/// Conventions:
///  - Every mutation stamps `client_updated_at` with the current time
///    (last-write-wins prep — DESIGN.md §5 / ARCHITECTURE.md §4.3).
///  - `owner` is a required relation the server does NOT auto-populate, so it is
///    set from the authenticated user on create (mirrors the web M1 fix).
///  - Soft delete = set `deleted_at`; never hard-delete from the UI.
///  - List queries exclude soft-deleted records (`deleted_at = ""`).
public struct DeckRepository: Sendable {

    /// Integer gap between duplicated card positions (1000, 2000, …).
    public static let positionGap = CardRepository.positionGap

    /// Max length of a deck `name` — the server rejects >200
    /// (ARCHITECTURE.md §3.2). Used to clamp the duplicate " (copy)" name.
    public static let nameMaxLength = 200

    private let client: APIClient
    private let collection = "decks"
    private let cardsCollection = "cards"

    /// Clock injected for testability; defaults to wall-clock `Date.init`.
    private let now: @Sendable () -> Date

    /// Optional image repository used to copy a source card's images onto the
    /// duplicated card (item 4). Defaulted to `nil` so existing call sites/tests
    /// that only need deck+card CRUD keep compiling and skip image-copy entirely.
    private let imageRepository: ImageRepositing?

    /// Downloads the bytes for a resolved (token-bearing) image file URL.
    /// Injectable for tests; the default fetches through the dedicated
    /// non-persisting ``ProtectedImageSession`` (SEC-IOS-B) so decrypted private
    /// `card_images` bytes are never written to the process-global
    /// `URLCache.shared` — NOT `URLSession.shared`.
    private let downloadImage: @Sendable (URL) async throws -> Data

    public init(
        client: APIClient,
        now: @escaping @Sendable () -> Date = Date.init,
        imageRepository: ImageRepositing? = nil,
        downloadImage: @escaping @Sendable (URL) async throws -> Data = { url in
            try await ProtectedImageSession.make().data(from: url).0
        }
    ) {
        self.client = client
        self.now = now
        self.imageRepository = imageRepository
        self.downloadImage = downloadImage
    }

    // MARK: - Read

    /// List non-soft-deleted decks the current user can see, newest-updated first.
    ///
    /// The PocketBase `listRule` already scopes results to owner/guest decks; we
    /// only filter out soft-deleted ones here. Page-level grouping/sorting
    /// happens in ``DeckGrouping``.
    ///
    /// Fetches *every* matching deck across all pages (mirrors the web
    /// `getFullList`); a single-page `list` call would silently drop decks beyond
    /// the first page for users with many decks.
    public func listDecks() async throws -> [Deck] {
        return try await client.listAll(
            Deck.self,
            collection: collection,
            perPage: 200,
            filter: "deleted_at = \"\"",
            sort: "-updated"
        )
    }

    /// Fetch a single non-soft-deleted deck by id.
    ///
    /// Scopes the fetch with `deleted_at = ""` so a soft-deleted deck reads as
    /// not-found, matching the list paths and the soft-delete model.
    public func getDeck(id: String) async throws -> Deck {
        let response = try await client.list(
            Deck.self,
            collection: collection,
            perPage: 1,
            filter: "id = \(PocketBaseFilter.quoted(id)) && deleted_at = \"\""
        )
        guard let deck = response.items.first else {
            throw DeckRepositoryError.notFound(id: id)
        }
        return deck
    }

    /// List the current user's soft-deleted decks (the trash view),
    /// most-recently-deleted first.
    ///
    /// Fetches *every* matching deck across all pages (mirrors the web
    /// `getFullList`) so a trash view with many decks is not truncated.
    public func listTrashedDecks() async throws -> [Deck] {
        return try await client.listAll(
            Deck.self,
            collection: collection,
            perPage: 200,
            filter: "deleted_at != \"\"",
            sort: "-deleted_at"
        )
    }

    // MARK: - Write

    /// Create a new deck for the given owner.
    ///
    /// `owner` is required and not auto-populated by the server, so the caller
    /// must pass the authenticated user id. An unset `shootDate` is sent as `""`
    /// to match PocketBase's "unset datetime" representation. `name` is clamped
    /// to the DB ceiling (``nameMaxLength``, ARCHITECTURE.md §3.2 max 200) so an
    /// over-long name never reaches the server as an opaque rejection (web
    /// `deckApi.ts` `maxLength={200}` input parity).
    @discardableResult
    public func createDeck(
        name: String,
        shootDate: Date? = nil,
        ownerId: String
    ) async throws -> Deck {
        let body = CreateDeckBody(
            owner: ownerId,
            name: String(name.prefix(Self.nameMaxLength)),
            shoot_date: shootDate.map(PocketBaseDate.string(from:)) ?? "",
            deleted_at: "",
            client_updated_at: PocketBaseDate.string(from: now())
        )
        return try await client.create(collection: collection, body: body)
    }

    /// Rename a deck.
    ///
    /// `name` is clamped to the DB ceiling (``nameMaxLength``, ARCHITECTURE.md
    /// §3.2 max 200) so an over-long name never reaches the server as an opaque
    /// rejection — mirrors the web `deckApi.ts` `maxLength={200}` input cap and
    /// the create/duplicate clamps.
    @discardableResult
    public func renameDeck(id: String, name: String) async throws -> Deck {
        let body = RenameBody(
            name: String(name.prefix(Self.nameMaxLength)),
            client_updated_at: PocketBaseDate.string(from: now())
        )
        return try await client.update(collection: collection, id: id, body: body)
    }

    /// Set/clear a deck's shoot date.
    @discardableResult
    public func setShootDate(id: String, shootDate: Date?) async throws -> Deck {
        let body = ShootDateBody(
            shoot_date: shootDate.map(PocketBaseDate.string(from:)) ?? "",
            client_updated_at: PocketBaseDate.string(from: now())
        )
        return try await client.update(collection: collection, id: id, body: body)
    }

    /// Soft-delete a deck (move to trash). Never hard-deletes.
    @discardableResult
    public func softDeleteDeck(id: String) async throws -> Deck {
        let stamp = PocketBaseDate.string(from: now())
        let body = SoftDeleteBody(deleted_at: stamp, client_updated_at: stamp)
        return try await client.update(collection: collection, id: id, body: body)
    }

    /// Restore a soft-deleted deck (clear `deleted_at`).
    @discardableResult
    public func restoreDeck(id: String) async throws -> Deck {
        let body = RestoreBody(deleted_at: "", client_updated_at: PocketBaseDate.string(from: now()))
        return try await client.update(collection: collection, id: id, body: body)
    }

    /// Duplicate a deck (poor-man's templates, DESIGN.md §3.3).
    ///
    /// Copies the deck metadata into a fresh deck (name suffixed " (copy)", no
    /// `shoot_date` carried over) and copies every non-soft-deleted card with
    /// freshly striped integer-gap positions, preserving order. Completions are
    /// NOT copied (they are per-user/permanent).
    ///
    /// When an ``ImageRepositing`` is injected, each copied card's images are
    /// copied too on a **best-effort** basis (item 4): the source bytes are
    /// downloaded through the protected, non-persisting session (SEC-IOS-B) and
    /// re-uploaded onto the copy card at the same position. Each image copy runs
    /// in its own `do`/`catch`; one failure is logged and skipped and never fails
    /// the duplicate (the cards always copy regardless). When no image repository
    /// is injected, images are skipped entirely (legacy behaviour).
    ///
    /// Only valid for *live* source decks: `getDeck` already excludes
    /// soft-deleted decks, so a trashed deck reads as not-found here.
    @discardableResult
    public func duplicateDeck(id: String, ownerId: String) async throws -> Deck {
        let source = try await getDeck(id: id)

        // Clamp the copy name to the DB ceiling (ARCHITECTURE.md §3.2, max 200):
        // a source name within 7 chars of 200 would otherwise overflow once the
        // " (copy)" suffix is appended and the server create would be rejected
        // (web `deckApi.ts` parity).
        let suffix = " (copy)"
        let base = String(source.name.prefix(Self.nameMaxLength - suffix.count))
        let copy = try await createDeck(
            name: base + suffix,
            shootDate: nil,
            ownerId: ownerId
        )

        // Fetch *all* non-deleted source cards in order, paginating across every
        // page (mirrors the web `getFullList`). A single-page `list` call would
        // silently drop cards beyond the first page for decks with many cards.
        let sourceCards = try await client.listAll(
            Card.self,
            collection: cardsCollection,
            perPage: 200,
            filter: "deck = \(PocketBaseFilter.quoted(id)) && deleted_at = \"\"",
            sort: "position"
        )

        var position = Self.positionGap
        for card in sourceCards {
            let body = DuplicateCardBody(
                deck: copy.id,
                position: position,
                title: card.title,
                time_slot: card.timeSlot ?? "",
                subjects: card.subjects ?? "",
                direction: card.direction ?? "",
                notes: card.notes ?? "",
                deleted_at: "",
                client_updated_at: PocketBaseDate.string(from: now())
            )
            let copyCard: Card = try await client.create(collection: cardsCollection, body: body)
            // Best-effort: copy the source card's images onto the new card. Only
            // runs when an image repository is injected; otherwise images are
            // skipped (legacy behaviour). Never fails the duplicate.
            if let imageRepository {
                await copyImages(from: card, to: copyCard, using: imageRepository)
            }
            position += Self.positionGap
        }

        return copy
    }

    /// Best-effort copy of every image on `source` onto `destination`, preserving
    /// each image's position.
    ///
    /// Each image is handled in its own `do`/`catch`: a failed token mint,
    /// download, or upload (including the per-card cap throwing) is logged and
    /// skipped so a single bad image never aborts the duplicate or the remaining
    /// images. Bytes are fetched through the injected protected-session download
    /// closure (SEC-IOS-B), NOT `URLSession.shared`, so the already-compressed
    /// JPEG is re-uploaded without ever touching the shared on-disk HTTP cache.
    private func copyImages(
        from source: Card,
        to destination: Card,
        using imageRepository: ImageRepositing
    ) async {
        let sourceImages: [CardImage]
        do {
            sourceImages = try await imageRepository.listCardImages(cardId: source.id)
        } catch {
            // Can't list the source images — skip image copy for this card.
            return
        }
        for image in sourceImages {
            do {
                let url = try await imageRepository.fileURL(for: image)
                let data = try await downloadImage(url)
                _ = try await imageRepository.uploadCardImage(
                    cardId: destination.id,
                    data: data,
                    position: image.position
                )
            } catch {
                // Best-effort: log and continue. One image's failure (token mint,
                // download, upload, or hitting the per-card cap) must not abort
                // the duplicate or block the remaining images.
                continue
            }
        }
    }

    // MARK: - Encodable bodies

    struct CreateDeckBody: Encodable, Sendable {
        let owner: String
        let name: String
        let shoot_date: String
        let deleted_at: String
        let client_updated_at: String
    }

    struct RenameBody: Encodable, Sendable {
        let name: String
        let client_updated_at: String
    }

    struct ShootDateBody: Encodable, Sendable {
        let shoot_date: String
        let client_updated_at: String
    }

    struct SoftDeleteBody: Encodable, Sendable {
        let deleted_at: String
        let client_updated_at: String
    }

    struct RestoreBody: Encodable, Sendable {
        let deleted_at: String
        let client_updated_at: String
    }

    struct DuplicateCardBody: Encodable, Sendable {
        let deck: String
        let position: Int
        let title: String
        let time_slot: String
        let subjects: String
        let direction: String
        let notes: String
        let deleted_at: String
        let client_updated_at: String
    }
}

/// Errors surfaced by ``DeckRepository``.
public enum DeckRepositoryError: Error, Equatable, Sendable {
    /// No live (non-soft-deleted) deck exists with this id.
    case notFound(id: String)
}
