import XCTest
@testable import PoseDeckCore

/// Tests for `DeckRepository` mutation bodies (owner stamping, soft-delete,
/// duplicate position striping), exercised offline via `StubURLProtocol`.
final class DeckRepositoryTests: XCTestCase {

    override func tearDown() {
        StubURLProtocol.shared.reset()
        super.tearDown()
    }

    private static let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
    private var fixedNow: Date { Self.fixedNow }

    private func makeClient() async -> APIClient {
        let client = APIClient(baseURL: URL(string: "http://stub.local")!, session: StubURLProtocol.makeSession())
        await client.setAuthToken("test-token")
        return client
    }

    func testCreateDeckStampsOwnerAndClientUpdatedAt() async throws {
        StubURLProtocol.shared.setHandler { _ in
            (200, Data(#"{"id":"d1","owner":"u_owner","name":"New deck","deleted_at":""}"#.utf8))
        }
        let repo = DeckRepository(client: await makeClient(), now: { Self.fixedNow })
        _ = try await repo.createDeck(name: "New deck", shootDate: nil, ownerId: "u_owner")

        let body = try lastBody()
        XCTAssertEqual(body["owner"] as? String, "u_owner", "owner must be set on create")
        XCTAssertEqual(body["shoot_date"] as? String, "", "unset shoot_date is empty string")
        XCTAssertEqual(body["deleted_at"] as? String, "")
        XCTAssertEqual(body["client_updated_at"] as? String, PocketBaseDate.string(from: fixedNow))
    }

    func testCreateDeckWithShootDateSerializesWireFormat() async throws {
        StubURLProtocol.shared.setHandler { _ in
            (200, Data(#"{"id":"d1","owner":"u","name":"X","deleted_at":""}"#.utf8))
        }
        let repo = DeckRepository(client: await makeClient(), now: { Self.fixedNow })
        let shoot = PocketBaseDate.date(from: "2026-07-04 08:00:00.000Z")!
        _ = try await repo.createDeck(name: "X", shootDate: shoot, ownerId: "u")
        let body = try lastBody()
        XCTAssertEqual(body["shoot_date"] as? String, "2026-07-04 08:00:00.000Z")
    }

    func testSoftDeleteSetsDeletedAt() async throws {
        StubURLProtocol.shared.setHandler { _ in
            (200, Data(#"{"id":"d1","owner":"u","name":"X","deleted_at":"2023-11-14 22:13:20.000Z"}"#.utf8))
        }
        let repo = DeckRepository(client: await makeClient(), now: { Self.fixedNow })
        _ = try await repo.softDeleteDeck(id: "d1")
        let body = try lastBody()
        let stamp = PocketBaseDate.string(from: fixedNow)
        XCTAssertEqual(body["deleted_at"] as? String, stamp)
        XCTAssertEqual(body["client_updated_at"] as? String, stamp)
    }

    func testRestoreClearsDeletedAt() async throws {
        StubURLProtocol.shared.setHandler { _ in
            (200, Data(#"{"id":"d1","owner":"u","name":"X","deleted_at":""}"#.utf8))
        }
        let repo = DeckRepository(client: await makeClient(), now: { Self.fixedNow })
        _ = try await repo.restoreDeck(id: "d1")
        let body = try lastBody()
        XCTAssertEqual(body["deleted_at"] as? String, "", "restore clears deleted_at")
    }

    func testGetDeckNotFoundWhenEmptyList() async throws {
        StubURLProtocol.shared.setHandler { _ in
            (200, Data(#"{"page":1,"perPage":1,"totalItems":0,"totalPages":0,"items":[]}"#.utf8))
        }
        let repo = DeckRepository(client: await makeClient(), now: { Self.fixedNow })
        do {
            _ = try await repo.getDeck(id: "missing")
            XCTFail("expected notFound")
        } catch let DeckRepositoryError.notFound(id) {
            XCTAssertEqual(id, "missing")
        }
    }

    func testDuplicateDeckCopiesCardsWithFreshGapPositions() async throws {
        // Sequence of calls:
        // 1. GET getDeck -> source deck (list envelope, 1 item)
        // 2. POST createDeck -> copy
        // 3. GET source cards -> 2 cards
        // 4. POST card copy x2
        StubURLProtocol.shared.setHandler { request in
            if request.httpMethod == "GET" {
                let url = request.url!.absoluteString
                if url.contains("collections/decks") {
                    let body = #"{"page":1,"perPage":1,"totalItems":1,"totalPages":1,"items":[{"id":"src","owner":"u","name":"Beach","shoot_date":"2026-07-04 08:00:00.000Z","deleted_at":""}]}"#
                    return (200, Data(body.utf8))
                }
                // cards list
                let body = """
                {"page":1,"perPage":200,"totalItems":2,"totalPages":1,"items":[
                  {"id":"c1","deck":"src","position":1000,"title":"First","notes":"n1","deleted_at":""},
                  {"id":"c2","deck":"src","position":5000,"title":"Second","deleted_at":""}
                ]}
                """
                return (200, Data(body.utf8))
            }
            // POST: decks create then cards create — echo something valid.
            let url = request.url!.absoluteString
            if url.contains("collections/decks") {
                return (200, Data(#"{"id":"copy","owner":"u","name":"Beach (copy)","deleted_at":""}"#.utf8))
            }
            return (200, Data(#"{"id":"newcard","deck":"copy","position":1000,"title":"x","deleted_at":""}"#.utf8))
        }

        let repo = DeckRepository(client: await makeClient(), now: { Self.fixedNow })
        let copy = try await repo.duplicateDeck(id: "src", ownerId: "u")
        XCTAssertEqual(copy.id, "copy")

        // Verify: deck-create body suffixes "(copy)" and drops shoot_date.
        let postBodies = try allPostBodies()
        let deckBody = postBodies.first { ($0["name"] as? String)?.contains("(copy)") == true }
        XCTAssertNotNil(deckBody, "copy deck name must be suffixed (copy)")
        XCTAssertEqual(deckBody?["shoot_date"] as? String, "", "duplicate must not carry shoot_date")

        // Card copies get fresh gap positions 1000, 2000 (NOT the source 1000/5000).
        let cardBodies = postBodies.filter { $0["deck"] as? String == "copy" }
        XCTAssertEqual(cardBodies.count, 2)
        let positions = cardBodies.compactMap { $0["position"] as? Int }.sorted()
        XCTAssertEqual(positions, [1000, 2000], "duplicated cards get fresh integer-gap positions")
        // Title/notes preserved.
        XCTAssertTrue(cardBodies.contains { $0["title"] as? String == "First" })
        XCTAssertTrue(cardBodies.contains { ($0["notes"] as? String) == "n1" })
    }

    /// Regression (CORR-1): a source deck with more cards than fit on one page
    /// must have *every* card copied — `duplicateDeck` paginates rather than
    /// silently dropping the overflow beyond the first page (web `getFullList`
    /// parity). Here the source has 250 cards spread over two pages of 200.
    func testDuplicateDeckCopiesCardsAcrossAllPages() async throws {
        let totalCards = 250
        let pageSize = 200

        StubURLProtocol.shared.setHandler { request in
            if request.httpMethod == "GET" {
                let url = request.url!.absoluteString
                if url.contains("collections/decks") {
                    let body = #"{"page":1,"perPage":1,"totalItems":1,"totalPages":1,"items":[{"id":"src","owner":"u","name":"Big","shoot_date":"","deleted_at":""}]}"#
                    return (200, Data(body.utf8))
                }
                // cards list — serve the requested page.
                let comps = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
                let page = Int(comps?.queryItems?.first { $0.name == "page" }?.value ?? "1") ?? 1
                let totalPages = (totalCards + pageSize - 1) / pageSize
                let start = (page - 1) * pageSize
                let end = min(start + pageSize, totalCards)
                let items = (start..<end).map { i in
                    #"{"id":"c\#(i)","deck":"src","position":\#((i + 1) * 1000),"title":"Card \#(i)","deleted_at":""}"#
                }.joined(separator: ",")
                let body = #"{"page":\#(page),"perPage":\#(pageSize),"totalItems":\#(totalCards),"totalPages":\#(totalPages),"items":[\#(items)]}"#
                return (200, Data(body.utf8))
            }
            let url = request.url!.absoluteString
            if url.contains("collections/decks") {
                return (200, Data(#"{"id":"copy","owner":"u","name":"Big (copy)","deleted_at":""}"#.utf8))
            }
            return (200, Data(#"{"id":"newcard","deck":"copy","position":1000,"title":"x","deleted_at":""}"#.utf8))
        }

        let repo = DeckRepository(client: await makeClient(), now: { Self.fixedNow })
        let copy = try await repo.duplicateDeck(id: "src", ownerId: "u")
        XCTAssertEqual(copy.id, "copy")

        // Every one of the 250 source cards must be copied into the new deck,
        // not just the first page of 200.
        let cardBodies = try allPostBodies().filter { $0["deck"] as? String == "copy" }
        XCTAssertEqual(cardBodies.count, totalCards, "all cards across every page must be copied")

        // Copies get fresh, contiguous gap positions 1000..250_000.
        let positions = cardBodies.compactMap { $0["position"] as? Int }.sorted()
        XCTAssertEqual(positions, (1...totalCards).map { $0 * 1000 })
    }

    /// Regression (spec-dup-name-overflow-ios): duplicating a deck whose name is
    /// within 7 chars of the 200-char DB ceiling must clamp the base name before
    /// appending " (copy)" so the resulting name never exceeds 200 — otherwise
    /// the server create is rejected (web `deckApi.ts` clamp parity,
    /// ARCHITECTURE.md §3.2 max 200).
    func testDuplicateDeckClampsCopyNameToDbCeiling() async throws {
        // 200-char source name (exactly at the ceiling).
        let longName = String(repeating: "A", count: DeckRepository.nameMaxLength)

        StubURLProtocol.shared.setHandler { request in
            if request.httpMethod == "GET" {
                let url = request.url!.absoluteString
                if url.contains("collections/decks") {
                    let body = #"{"page":1,"perPage":1,"totalItems":1,"totalPages":1,"items":[{"id":"src","owner":"u","name":"\#(longName)","shoot_date":"","deleted_at":""}]}"#
                    return (200, Data(body.utf8))
                }
                // No cards on the source.
                return (200, Data(#"{"page":1,"perPage":200,"totalItems":0,"totalPages":0,"items":[]}"#.utf8))
            }
            return (200, Data(#"{"id":"copy","owner":"u","name":"x","deleted_at":""}"#.utf8))
        }

        let repo = DeckRepository(client: await makeClient(), now: { Self.fixedNow })
        _ = try await repo.duplicateDeck(id: "src", ownerId: "u")

        let body = try lastBody()
        let copyName = try XCTUnwrap(body["name"] as? String, "duplicate must send a name")
        XCTAssertLessThanOrEqual(
            copyName.count, DeckRepository.nameMaxLength,
            "copy name must be clamped to the 200-char DB ceiling"
        )
        XCTAssertTrue(copyName.hasSuffix(" (copy)"), "clamped name must still carry the (copy) suffix")
        // The base is truncated by exactly the suffix length so the full name lands on 200.
        XCTAssertEqual(copyName.count, DeckRepository.nameMaxLength)
    }

    // MARK: - name length clamp (SPEC-IOS-1 regression)

    /// Regression (SPEC-IOS-1): `createDeck` must clamp an over-long `name` to the
    /// 200-char DB ceiling (ARCHITECTURE.md §3.2) before sending it, mirroring the
    /// web `deckApi.ts` `maxLength={200}` input cap. Previously the raw name went
    /// straight into the create body, so a >200-char name produced an opaque
    /// server rejection ("Something went wrong") with no client-side prevention.
    func testCreateDeckClampsOverlongNameToDbCeiling() async throws {
        StubURLProtocol.shared.setHandler { _ in
            (200, Data(#"{"id":"d1","owner":"u","name":"x","deleted_at":""}"#.utf8))
        }
        let repo = DeckRepository(client: await makeClient(), now: { Self.fixedNow })
        let overlong = String(repeating: "A", count: DeckRepository.nameMaxLength + 50)
        _ = try await repo.createDeck(name: overlong, ownerId: "u")

        let body = try lastBody()
        let sent = try XCTUnwrap(body["name"] as? String, "create must send a name")
        XCTAssertEqual(sent.count, DeckRepository.nameMaxLength, "name clamped to the 200-char DB ceiling")
    }

    /// Regression (SPEC-IOS-1): `renameDeck` must likewise clamp an over-long
    /// `name` to the DB ceiling before the PATCH, so a long rename never surfaces
    /// as an opaque server error (web `deckApi.ts` `maxLength={200}` parity).
    func testRenameDeckClampsOverlongNameToDbCeiling() async throws {
        StubURLProtocol.shared.setHandler { _ in
            (200, Data(#"{"id":"d1","owner":"u","name":"x","deleted_at":""}"#.utf8))
        }
        let repo = DeckRepository(client: await makeClient(), now: { Self.fixedNow })
        let overlong = String(repeating: "B", count: DeckRepository.nameMaxLength + 50)
        _ = try await repo.renameDeck(id: "d1", name: overlong)

        let body = try lastBody()
        let sent = try XCTUnwrap(body["name"] as? String, "rename must send a name")
        XCTAssertEqual(sent.count, DeckRepository.nameMaxLength, "name clamped to the 200-char DB ceiling")
    }

    /// A name at or under the ceiling must pass through unchanged (the clamp is a
    /// ceiling, not a transform).
    func testCreateDeckLeavesInBoundsNameUnchanged() async throws {
        StubURLProtocol.shared.setHandler { _ in
            (200, Data(#"{"id":"d1","owner":"u","name":"x","deleted_at":""}"#.utf8))
        }
        let repo = DeckRepository(client: await makeClient(), now: { Self.fixedNow })
        _ = try await repo.createDeck(name: "Smith Wedding", ownerId: "u")
        let body = try lastBody()
        XCTAssertEqual(body["name"] as? String, "Smith Wedding")
    }

    // MARK: - list pagination (CORR-2 regression)

    /// Regression for CORR-2: a user with more decks than fit on one page must
    /// not have the list truncated. `listDecks` walks every page via `listAll`
    /// (web `getFullList` parity) rather than returning only the first 200.
    func testListDecksFetchesEveryPage() async throws {
        try await assertListPaginates(
            filterContains: "deleted_at = \"\"",
            idPrefix: "d"
        ) { repo in try await repo.listDecks() }
    }

    /// Regression for CORR-2: the trash view must likewise fetch every page so a
    /// user with >200 trashed decks sees all of them.
    func testListTrashedDecksFetchesEveryPage() async throws {
        try await assertListPaginates(
            filterContains: "deleted_at != \"\"",
            idPrefix: "t"
        ) { repo in try await repo.listTrashedDecks() }
    }

    /// Drives a list method against a 3-page (450-deck) stub and asserts every
    /// record is returned and one GET is issued per page.
    private func assertListPaginates(
        filterContains: String,
        idPrefix: String,
        _ call: (DeckRepository) async throws -> [Deck]
    ) async throws {
        let perPage = 200
        let total = 450
        let totalPages = 3

        StubURLProtocol.shared.setHandler { request in
            guard request.httpMethod == "GET" else { return (200, Data("{}".utf8)) }
            let comps = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
            let page = Int(comps?.queryItems?.first { $0.name == "page" }?.value ?? "1") ?? 1
            let start = (page - 1) * perPage
            let end = min(start + perPage, total)
            let items = (start..<end).map { i in
                #"{"id":"\#(idPrefix)\#(i)","owner":"u","name":"Deck \#(i)","deleted_at":""}"#
            }.joined(separator: ",")
            let body = #"{"page":\#(page),"perPage":\#(perPage),"totalItems":\#(total),"totalPages":\#(totalPages),"items":[\#(items)]}"#
            return (200, Data(body.utf8))
        }

        let repo = DeckRepository(client: await makeClient(), now: { Self.fixedNow })
        let decks = try await call(repo)

        XCTAssertEqual(decks.count, total, "all decks across every page must be returned, not just the first 200")
        XCTAssertEqual(decks.first?.id, "\(idPrefix)0")
        XCTAssertEqual(decks.last?.id, "\(idPrefix)449", "records beyond the first page must not be dropped")

        let getRequests = StubURLProtocol.shared.requests.filter { $0.httpMethod == "GET" }
        XCTAssertEqual(getRequests.count, totalPages, "should issue one GET per page")
        // Sanity: the expected filter was actually used.
        let url = getRequests.first?.url?.absoluteString ?? ""
        let decoded = url.removingPercentEncoding ?? url
        XCTAssertTrue(decoded.contains(filterContains), "filter must be preserved across pagination")
    }

    // MARK: - helpers

    private func lastBody() throws -> [String: Any] {
        let bodies = StubURLProtocol.shared.bodies
        let requests = StubURLProtocol.shared.requests
        for i in stride(from: bodies.count - 1, through: 0, by: -1) {
            let method = requests[i].httpMethod
            if (method == "POST" || method == "PATCH"), !bodies[i].isEmpty {
                return try JSONSerialization.jsonObject(with: bodies[i]) as? [String: Any] ?? [:]
            }
        }
        return [:]
    }

    private func allPostBodies() throws -> [[String: Any]] {
        let bodies = StubURLProtocol.shared.bodies
        let requests = StubURLProtocol.shared.requests
        var result: [[String: Any]] = []
        for i in bodies.indices {
            let method = requests[i].httpMethod
            if (method == "POST" || method == "PATCH"), !bodies[i].isEmpty,
               let obj = try JSONSerialization.jsonObject(with: bodies[i]) as? [String: Any] {
                result.append(obj)
            }
        }
        return result
    }
}
