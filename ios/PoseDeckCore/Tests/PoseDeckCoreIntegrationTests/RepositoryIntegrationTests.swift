import Foundation
import XCTest
@testable import PoseDeckCore

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Live-backend integration tests for the PoseDeckCore repositories.
///
/// These exercise the REAL PocketBase contract (auth, collection rules, file
/// tokens) rather than a stub, so they are gated behind `POSEDECK_INTEGRATION=1`
/// (see ``IntegrationEnvironment``). With the gate off — the default — every
/// test calls ``IntegrationEnvironment/skipIfDisabled()`` and is recorded as
/// skipped, keeping the offline `swift test` run green.
///
/// Every test cleans up the records it creates (hard-deleting via the repos /
/// client) so re-runs stay idempotent and the seed data is left untouched.
final class RepositoryIntegrationTests: XCTestCase {

    /// Records created during a test, hard-deleted in teardown regardless of
    /// outcome so a failing assertion never leaves orphans behind.
    private struct Cleanup {
        var deckIds: [String] = []
        var cardIds: [String] = []
        var imageIds: [String] = []
        var guestIds: [String] = []
    }

    // MARK: - Auth

    func testAuthWithSeedOwnerReturnsTokenAndUserId() async throws {
        try IntegrationEnvironment.skipIfDisabled()
        let client = IntegrationEnvironment.makeClient()

        let auth = try await client.authWithPassword(
            email: IntegrationEnvironment.ownerEmail,
            password: IntegrationEnvironment.ownerPassword
        )

        XCTAssertFalse(auth.token.isEmpty, "auth must return a non-empty JWT")
        XCTAssertFalse(auth.record.id.isEmpty, "auth must return the user record id")
        XCTAssertEqual(auth.record.email, IntegrationEnvironment.ownerEmail)
    }

    func testAuthWithWrongPasswordFails() async throws {
        try IntegrationEnvironment.skipIfDisabled()
        let client = IntegrationEnvironment.makeClient()

        do {
            _ = try await client.authWithPassword(
                email: IntegrationEnvironment.ownerEmail,
                password: "definitely-not-the-password"
            )
            XCTFail("expected auth to reject a wrong password")
        } catch let APIClientError.httpError(status, _) {
            XCTAssertEqual(status, 400, "PocketBase returns 400 for bad credentials")
        }
    }

    // MARK: - Deck create (owner required) + soft-delete exclusion

    func testCreateDeckRequiresOwnerAndAppearsInList() async throws {
        try IntegrationEnvironment.skipIfDisabled()
        let client = IntegrationEnvironment.makeClient()
        var cleanup = Cleanup()
        defer { hardCleanup(client: client, cleanup: cleanup) }

        let auth = try await client.authWithPassword(
            email: IntegrationEnvironment.ownerEmail,
            password: IntegrationEnvironment.ownerPassword
        )
        let repo = DeckRepository(client: client)

        let name = uniqueName("integ-deck")
        let deck = try await repo.createDeck(name: name, ownerId: auth.record.id)
        cleanup.deckIds.append(deck.id)

        XCTAssertEqual(deck.owner, auth.record.id, "owner must be persisted (server does not auto-populate it)")
        XCTAssertEqual(deck.name, name)
        XCTAssertNil(deck.deletedAt, "a freshly created deck is not soft-deleted")

        let listed = try await repo.listDecks()
        XCTAssertTrue(listed.contains { $0.id == deck.id }, "new deck must appear in the live list")
    }

    func testCreateDeckWithoutOwnerIsRejectedByServer() async throws {
        try IntegrationEnvironment.skipIfDisabled()
        let client = IntegrationEnvironment.makeClient()

        _ = try await client.authWithPassword(
            email: IntegrationEnvironment.ownerEmail,
            password: IntegrationEnvironment.ownerPassword
        )

        // owner is a required relation; sending "" must be rejected (400),
        // proving the repo's "owner required on create" contract is real.
        struct BadDeckBody: Encodable { let owner: String; let name: String; let client_updated_at: String }
        let body = BadDeckBody(owner: "", name: uniqueName("integ-bad"), client_updated_at: "")
        do {
            let _: Deck = try await client.create(collection: "decks", body: body)
            XCTFail("server must reject a deck with no owner")
        } catch let APIClientError.httpError(status, _) {
            XCTAssertEqual(status, 400, "missing required owner relation must 400")
        }
    }

    func testListExcludesSoftDeletedDecks() async throws {
        try IntegrationEnvironment.skipIfDisabled()
        let client = IntegrationEnvironment.makeClient()
        var cleanup = Cleanup()
        defer { hardCleanup(client: client, cleanup: cleanup) }

        let auth = try await client.authWithPassword(
            email: IntegrationEnvironment.ownerEmail,
            password: IntegrationEnvironment.ownerPassword
        )
        let repo = DeckRepository(client: client)

        let deck = try await repo.createDeck(name: uniqueName("integ-trash"), ownerId: auth.record.id)
        cleanup.deckIds.append(deck.id)

        // Visible before delete.
        let before = try await repo.listDecks()
        XCTAssertTrue(before.contains { $0.id == deck.id })

        let trashed = try await repo.softDeleteDeck(id: deck.id)
        XCTAssertNotNil(trashed.deletedAt, "soft delete must stamp deleted_at on the live record")

        // Excluded from the live list, but present in trash.
        let after = try await repo.listDecks()
        XCTAssertFalse(after.contains { $0.id == deck.id }, "soft-deleted deck must be excluded from listDecks")

        let trash = try await repo.listTrashedDecks()
        XCTAssertTrue(trash.contains { $0.id == deck.id }, "soft-deleted deck must appear in listTrashedDecks")
    }

    // MARK: - Card create / reorder positions

    func testCardCreatePositionsAndReorderRestripe() async throws {
        try IntegrationEnvironment.skipIfDisabled()
        let client = IntegrationEnvironment.makeClient()
        var cleanup = Cleanup()
        defer { hardCleanup(client: client, cleanup: cleanup) }

        let auth = try await client.authWithPassword(
            email: IntegrationEnvironment.ownerEmail,
            password: IntegrationEnvironment.ownerPassword
        )
        let deckRepo = DeckRepository(client: client)
        let cardRepo = CardRepository(client: client)

        let deck = try await deckRepo.createDeck(name: uniqueName("integ-cards"), ownerId: auth.record.id)
        cleanup.deckIds.append(deck.id)

        let a = try await cardRepo.createCard(deckId: deck.id, fields: .init(title: "Alpha"))
        let b = try await cardRepo.createCard(deckId: deck.id, fields: .init(title: "Bravo"))
        let c = try await cardRepo.createCard(deckId: deck.id, fields: .init(title: "Charlie"))
        cleanup.cardIds.append(contentsOf: [a.id, b.id, c.id])

        // Appended cards get clean integer-gap positions.
        XCTAssertEqual(a.position, 1000)
        XCTAssertEqual(b.position, 2000)
        XCTAssertEqual(c.position, 3000)

        // Title clamp (DESIGN.md §3 — 60 chars) enforced on the live write.
        let longTitle = String(repeating: "x", count: 80)
        let clamped = try await cardRepo.createCard(deckId: deck.id, fields: .init(title: longTitle))
        cleanup.cardIds.append(clamped.id)
        XCTAssertEqual(clamped.title.count, CardRepository.titleMaxLength, "title must be clamped to 60 on the live record")

        // Reorder to Charlie, Alpha, Bravo (drop the clamped one out of scope by
        // listing first to capture current positions).
        let current = try await cardRepo.listCards(deckId: deck.id)
        let positions = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0.position) })
        try await cardRepo.reorderCards(
            deckId: deck.id,
            orderedIds: [c.id, a.id, b.id, clamped.id],
            currentPositions: positions
        )

        let reordered = try await cardRepo.listCards(deckId: deck.id)
        XCTAssertEqual(reordered.map(\.id), [c.id, a.id, b.id, clamped.id], "list must reflect the reordered sequence")
        XCTAssertEqual(reordered.map(\.position), [1000, 2000, 3000, 4000], "positions must restripe to clean gaps")

        // Soft-deleted cards are excluded from listCards.
        _ = try await cardRepo.softDeleteCard(id: a.id)
        let afterDelete = try await cardRepo.listCards(deckId: deck.id)
        XCTAssertFalse(afterDelete.contains { $0.id == a.id }, "soft-deleted card excluded from listCards")
    }

    // MARK: - card_images upload + protected file token fetch

    func testUploadCardImageAndFetchProtectedFile() async throws {
        try IntegrationEnvironment.skipIfDisabled()
        let client = IntegrationEnvironment.makeClient()
        var cleanup = Cleanup()
        defer { hardCleanup(client: client, cleanup: cleanup) }

        let auth = try await client.authWithPassword(
            email: IntegrationEnvironment.ownerEmail,
            password: IntegrationEnvironment.ownerPassword
        )
        let deckRepo = DeckRepository(client: client)
        let cardRepo = CardRepository(client: client)
        let imageRepo = ImageRepository(client: client)

        let deck = try await deckRepo.createDeck(name: uniqueName("integ-img"), ownerId: auth.record.id)
        cleanup.deckIds.append(deck.id)
        let card = try await cardRepo.createCard(deckId: deck.id, fields: .init(title: "With image"))
        cleanup.cardIds.append(card.id)

        let jpeg = Self.minimalJPEG()
        let image = try await imageRepo.uploadCardImage(cardId: card.id, data: jpeg, position: 1000)
        cleanup.imageIds.append(image.id)

        XCTAssertEqual(image.card, card.id)
        XCTAssertNotNil(image.file, "uploaded record must carry the stored filename")
        XCTAssertFalse((image.file ?? "").isEmpty)

        // Listing returns it.
        let images = try await imageRepo.listCardImages(cardId: card.id)
        XCTAssertTrue(images.contains { $0.id == image.id })

        // Protected file: the repo mints a short-lived file token and builds a
        // ?token= URL (mirrors the web fix — GET /api/files/... for the protected
        // card_images collection must carry a token, not just the auth header).
        // The contract under test is: a real token is minted AND the tokened URL
        // returns the stored bytes.
        let tokenURL = try await imageRepo.fileURL(for: image)
        XCTAssertTrue(tokenURL.absoluteString.contains("token="), "card_images file URL must carry a ?token=")

        let queryItems = URLComponents(url: tokenURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let token = queryItems.first { $0.name == "token" }?.value
        XCTAssertNotNil(token, "fileURL must embed a minted token")
        XCTAssertFalse((token ?? "").isEmpty, "minted file token must be non-empty")

        let bytes = try await Self.fetch(tokenURL, session: URLSession(configuration: .ephemeral))
        XCTAssertFalse(bytes.isEmpty, "tokened file fetch must return the image bytes")
        XCTAssertEqual(Array(bytes.prefix(2)), [0xFF, 0xD8], "fetched bytes must be the JPEG we uploaded (SOI marker)")
    }

    // MARK: - Guest visibility

    func testGuestCanSeeSharedDeckButNotUnsharedOne() async throws {
        try IntegrationEnvironment.skipIfDisabled()
        let ownerClient = IntegrationEnvironment.makeClient()
        var cleanup = Cleanup()
        defer { hardCleanup(client: ownerClient, cleanup: cleanup) }

        let ownerAuth = try await ownerClient.authWithPassword(
            email: IntegrationEnvironment.ownerEmail,
            password: IntegrationEnvironment.ownerPassword
        )
        let ownerDeckRepo = DeckRepository(client: ownerClient)

        // Owner creates two decks; shares only one with the guest.
        let shared = try await ownerDeckRepo.createDeck(name: uniqueName("integ-shared"), ownerId: ownerAuth.record.id)
        let unshared = try await ownerDeckRepo.createDeck(name: uniqueName("integ-unshared"), ownerId: ownerAuth.record.id)
        cleanup.deckIds.append(contentsOf: [shared.id, unshared.id])

        // Resolve the guest's user id (auth as guest on a separate client).
        let guestClient = IntegrationEnvironment.makeClient()
        let guestAuth = try await guestClient.authWithPassword(
            email: IntegrationEnvironment.guestEmail,
            password: IntegrationEnvironment.guestPassword
        )

        // Owner grants the guest access (deck_guests row; only the owner may create it).
        struct GuestBody: Encodable { let deck: String; let user: String }
        let grant: DeckGuest = try await ownerClient.create(
            collection: "deck_guests",
            body: GuestBody(deck: shared.id, user: guestAuth.record.id)
        )
        cleanup.guestIds.append(grant.id)

        // The guest's view: shared deck visible, unshared deck not.
        let guestDeckRepo = DeckRepository(client: guestClient)
        let guestVisible = try await guestDeckRepo.listDecks()
        XCTAssertTrue(guestVisible.contains { $0.id == shared.id }, "guest must see a deck shared with them")
        XCTAssertFalse(guestVisible.contains { $0.id == unshared.id }, "guest must NOT see an unshared deck")
    }

    // MARK: - Cleanup helper

    /// Hard-delete every record a test created, ignoring failures (best-effort,
    /// so a partial failure mid-test still cleans up what exists). Order:
    /// images → guests → cards → decks (children before parents).
    private func hardCleanup(client: APIClient, cleanup: Cleanup) {
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            for id in cleanup.imageIds { try? await client.delete(collection: ImageRepository.collection, id: id) }
            for id in cleanup.guestIds { try? await client.delete(collection: "deck_guests", id: id) }
            for id in cleanup.cardIds { try? await client.delete(collection: "cards", id: id) }
            for id in cleanup.deckIds { try? await client.delete(collection: "decks", id: id) }
            semaphore.signal()
        }
        semaphore.wait()
    }

    // MARK: - Test fixtures

    private func uniqueName(_ prefix: String) -> String {
        "\(prefix)-\(UUID().uuidString.prefix(8))"
    }

    /// A tiny but valid JPEG (1x1) so PocketBase's image-field validation accepts
    /// the upload. Built from a known-good minimal baseline JPEG byte sequence.
    private static func minimalJPEG() -> Data {
        // Minimal 1x1 grayscale baseline JPEG.
        let bytes: [UInt8] = [
            0xFF,0xD8,0xFF,0xE0,0x00,0x10,0x4A,0x46,0x49,0x46,0x00,0x01,0x01,0x00,0x00,0x01,
            0x00,0x01,0x00,0x00,0xFF,0xDB,0x00,0x43,0x00,0x08,0x06,0x06,0x07,0x06,0x05,0x08,
            0x07,0x07,0x07,0x09,0x09,0x08,0x0A,0x0C,0x14,0x0D,0x0C,0x0B,0x0B,0x0C,0x19,0x12,
            0x13,0x0F,0x14,0x1D,0x1A,0x1F,0x1E,0x1D,0x1A,0x1C,0x1C,0x20,0x24,0x2E,0x27,0x20,
            0x22,0x2C,0x23,0x1C,0x1C,0x28,0x37,0x29,0x2C,0x30,0x31,0x34,0x34,0x34,0x1F,0x27,
            0x39,0x3D,0x38,0x32,0x3C,0x2E,0x33,0x34,0x32,0xFF,0xC0,0x00,0x0B,0x08,0x00,0x01,
            0x00,0x01,0x01,0x01,0x11,0x00,0xFF,0xC4,0x00,0x1F,0x00,0x00,0x01,0x05,0x01,0x01,
            0x01,0x01,0x01,0x01,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x01,0x02,0x03,0x04,
            0x05,0x06,0x07,0x08,0x09,0x0A,0x0B,0xFF,0xC4,0x00,0xB5,0x10,0x00,0x02,0x01,0x03,
            0x03,0x02,0x04,0x03,0x05,0x05,0x04,0x04,0x00,0x00,0x01,0x7D,0x01,0x02,0x03,0x00,
            0x04,0x11,0x05,0x12,0x21,0x31,0x41,0x06,0x13,0x51,0x61,0x07,0x22,0x71,0x14,0x32,
            0x81,0x91,0xA1,0x08,0x23,0x42,0xB1,0xC1,0x15,0x52,0xD1,0xF0,0x24,0x33,0x62,0x72,
            0x82,0x09,0x0A,0x16,0x17,0x18,0x19,0x1A,0x25,0x26,0x27,0x28,0x29,0x2A,0x34,0x35,
            0x36,0x37,0x38,0x39,0x3A,0x43,0x44,0x45,0x46,0x47,0x48,0x49,0x4A,0x53,0x54,0x55,
            0x56,0x57,0x58,0x59,0x5A,0x63,0x64,0x65,0x66,0x67,0x68,0x69,0x6A,0x73,0x74,0x75,
            0x76,0x77,0x78,0x79,0x7A,0x83,0x84,0x85,0x86,0x87,0x88,0x89,0x8A,0x92,0x93,0x94,
            0x95,0x96,0x97,0x98,0x99,0x9A,0xA2,0xA3,0xA4,0xA5,0xA6,0xA7,0xA8,0xA9,0xAA,0xB2,
            0xB3,0xB4,0xB5,0xB6,0xB7,0xB8,0xB9,0xBA,0xC2,0xC3,0xC4,0xC5,0xC6,0xC7,0xC8,0xC9,
            0xCA,0xD2,0xD3,0xD4,0xD5,0xD6,0xD7,0xD8,0xD9,0xDA,0xE1,0xE2,0xE3,0xE4,0xE5,0xE6,
            0xE7,0xE8,0xE9,0xEA,0xF1,0xF2,0xF3,0xF4,0xF5,0xF6,0xF7,0xF8,0xF9,0xFA,0xFF,0xDA,
            0x00,0x08,0x01,0x01,0x00,0x00,0x3F,0x00,0xD2,0xCF,0x20,0xFF,0xD9,
        ]
        return Data(bytes)
    }

    private enum HTTPFetchError: Error { case status(Int, Data); case notHTTP }

    /// Fetch a URL and return the body, throwing on non-2xx (so tests can assert
    /// on the denied/allowed contract for protected files).
    private static func fetch(_ url: URL, session: URLSession) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else { throw HTTPFetchError.notHTTP }
        guard (200..<300).contains(http.statusCode) else {
            throw HTTPFetchError.status(http.statusCode, data)
        }
        return data
    }
}
