import XCTest
@testable import PoseDeckCore

/// Wire-level assertions for repository CRUD: each mutation hits the *correct
/// collection path*, every read filter *excludes soft-deleted records*, reorder
/// restripes positions in the PATCH body, and duplicate *excludes deleted cards*
/// at the source query. Exercised fully offline via `StubURLProtocol`.
///
/// These complement `DeckRepositoryTests`/`CardRepositoryTests` (which assert
/// body field values) by pinning the request *target* (collection, method) and
/// the *filter strings* the data model depends on (ARCHITECTURE.md §3, soft
/// delete; DESIGN.md §3.3 list semantics).
final class RepositoryWirePayloadTests: XCTestCase {

    override func tearDown() {
        StubURLProtocol.shared.reset()
        super.tearDown()
    }

    private static let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
    private var fixedNow: Date { Self.fixedNow }
    private var stamp: String { PocketBaseDate.string(from: fixedNow) }

    private func makeClient() async -> APIClient {
        let client = APIClient(baseURL: URL(string: "http://stub.local")!, session: StubURLProtocol.makeSession())
        await client.setAuthToken("test-token")
        return client
    }

    private func deckRepo() async -> DeckRepository {
        DeckRepository(client: await makeClient(), now: { Self.fixedNow })
    }

    private func cardRepo() async -> CardRepository {
        CardRepository(client: await makeClient(), now: { Self.fixedNow })
    }

    /// Decoded query items of the most recent GET request, percent-decoded.
    private func lastGetQuery() -> [String: String] {
        let gets = StubURLProtocol.shared.requests.filter { $0.httpMethod == "GET" }
        guard let url = gets.last?.url,
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return [:] }
        var out: [String: String] = [:]
        for item in comps.queryItems ?? [] { out[item.name] = item.value }
        return out
    }

    private func requests(method: String) -> [URLRequest] {
        StubURLProtocol.shared.requests.filter { $0.httpMethod == method }
    }

    // MARK: - Correct collection path

    func testCreateDeckTargetsDecksRecordsEndpoint() async throws {
        StubURLProtocol.shared.setHandler { _ in
            (200, Data(#"{"id":"d1","owner":"u","name":"X","deleted_at":""}"#.utf8))
        }
        _ = try await (await deckRepo()).createDeck(name: "X", shootDate: nil, ownerId: "u")
        let posts = requests(method: "POST")
        XCTAssertEqual(posts.count, 1)
        XCTAssertEqual(posts.first?.url?.path, "/api/collections/decks/records",
                       "deck create must POST to the decks collection")
    }

    func testRenameDeckPatchesDeckByIdInDecksCollection() async throws {
        StubURLProtocol.shared.setHandler { _ in
            (200, Data(#"{"id":"d1","owner":"u","name":"Renamed","deleted_at":""}"#.utf8))
        }
        _ = try await (await deckRepo()).renameDeck(id: "d1", name: "Renamed")
        let patches = requests(method: "PATCH")
        XCTAssertEqual(patches.first?.url?.path, "/api/collections/decks/records/d1")
    }

    func testCreateCardTargetsCardsRecordsEndpoint() async throws {
        StubURLProtocol.shared.setHandler { request in
            if request.httpMethod == "GET" {
                return (200, Data(#"{"page":1,"perPage":200,"totalItems":0,"totalPages":0,"items":[]}"#.utf8))
            }
            return (200, Data(#"{"id":"c","deck":"d1","position":1000,"title":"x","deleted_at":""}"#.utf8))
        }
        _ = try await (await cardRepo()).createCard(deckId: "d1", fields: .init(title: "x"))
        let posts = requests(method: "POST")
        XCTAssertEqual(posts.first?.url?.path, "/api/collections/cards/records",
                       "card create must POST to the cards collection")
        // The preceding listCards read must target cards too.
        XCTAssertEqual(requests(method: "GET").first?.url?.path, "/api/collections/cards/records")
    }

    func testSoftDeleteCardPatchesCardByIdInCardsCollection() async throws {
        StubURLProtocol.shared.setHandler { _ in
            (200, Data(#"{"id":"c1","deck":"d1","position":1000,"title":"x","deleted_at":"2023-11-14 22:13:20.000Z"}"#.utf8))
        }
        _ = try await (await cardRepo()).softDeleteCard(id: "c1")
        XCTAssertEqual(requests(method: "PATCH").first?.url?.path, "/api/collections/cards/records/c1")
    }

    // MARK: - client_updated_at present on every mutation

    func testRenameDeckStampsClientUpdatedAt() async throws {
        StubURLProtocol.shared.setHandler { _ in
            (200, Data(#"{"id":"d1","owner":"u","name":"R","deleted_at":""}"#.utf8))
        }
        _ = try await (await deckRepo()).renameDeck(id: "d1", name: "R")
        XCTAssertEqual(try lastBody()["client_updated_at"] as? String, stamp,
                       "rename must stamp client_updated_at (LWW prep)")
    }

    func testSetShootDateStampsClientUpdatedAtAndClearsWithEmptyString() async throws {
        StubURLProtocol.shared.setHandler { _ in
            (200, Data(#"{"id":"d1","owner":"u","name":"X","deleted_at":""}"#.utf8))
        }
        _ = try await (await deckRepo()).setShootDate(id: "d1", shootDate: nil)
        let body = try lastBody()
        XCTAssertEqual(body["shoot_date"] as? String, "", "clearing shoot date sends empty string")
        XCTAssertEqual(body["client_updated_at"] as? String, stamp)
    }

    func testUpdateCardAlwaysIncludesClientUpdatedAtAndOmitsUnsetKeys() async throws {
        StubURLProtocol.shared.setHandler { _ in
            (200, Data(#"{"id":"c1","deck":"d1","position":1000,"title":"new","deleted_at":""}"#.utf8))
        }
        // Only `notes` provided -> body has notes + client_updated_at and nothing else.
        _ = try await (await cardRepo()).updateCard(id: "c1", fields: .init(notes: "hello"))
        let body = try lastBody()
        XCTAssertEqual(body["notes"] as? String, "hello")
        XCTAssertEqual(body["client_updated_at"] as? String, stamp)
        XCTAssertNil(body["title"], "unset keys must be omitted from the PATCH body")
        XCTAssertNil(body["subjects"])
        XCTAssertNil(body["direction"])
        XCTAssertNil(body["time_slot"])
    }

    // MARK: - Read filters exclude soft-deleted records

    func testListDecksFilterExcludesDeleted() async throws {
        StubURLProtocol.shared.setHandler { _ in
            (200, Data(#"{"page":1,"perPage":200,"totalItems":0,"totalPages":0,"items":[]}"#.utf8))
        }
        _ = try await (await deckRepo()).listDecks()
        let q = lastGetQuery()
        XCTAssertEqual(q["filter"], "deleted_at = \"\"", "list must exclude soft-deleted decks")
        XCTAssertEqual(q["sort"], "-updated")
    }

    func testGetDeckFilterScopesToLiveRecord() async throws {
        StubURLProtocol.shared.setHandler { _ in
            (200, Data(#"{"page":1,"perPage":1,"totalItems":1,"totalPages":1,"items":[{"id":"d1","owner":"u","name":"X","deleted_at":""}]}"#.utf8))
        }
        _ = try await (await deckRepo()).getDeck(id: "d1")
        let filter = lastGetQuery()["filter"] ?? ""
        XCTAssertTrue(filter.contains("id = \"d1\""), "must scope by id")
        XCTAssertTrue(filter.contains("deleted_at = \"\""),
                      "getDeck must read a soft-deleted record as not-found")
    }

    func testListTrashedDecksFilterIncludesOnlyDeleted() async throws {
        StubURLProtocol.shared.setHandler { _ in
            (200, Data(#"{"page":1,"perPage":200,"totalItems":0,"totalPages":0,"items":[]}"#.utf8))
        }
        _ = try await (await deckRepo()).listTrashedDecks()
        let q = lastGetQuery()
        XCTAssertEqual(q["filter"], "deleted_at != \"\"", "trash view shows only soft-deleted decks")
        XCTAssertEqual(q["sort"], "-deleted_at")
    }

    func testListCardsFilterScopesToDeckAndExcludesDeleted() async throws {
        StubURLProtocol.shared.setHandler { _ in
            (200, Data(#"{"page":1,"perPage":200,"totalItems":0,"totalPages":0,"items":[]}"#.utf8))
        }
        _ = try await (await cardRepo()).listCards(deckId: "d42")
        let q = lastGetQuery()
        XCTAssertEqual(q["filter"], "deck = \"d42\" && deleted_at = \"\"",
                       "listCards must scope to the deck and exclude soft-deleted cards")
        XCTAssertEqual(q["sort"], "position")
    }

    // MARK: - Reorder restripe (PATCH body carries new clean-gap positions)

    func testReorderRestripesPositionsInPatchBodies() async throws {
        StubURLProtocol.shared.setHandler { _ in
            (200, Data(#"{"id":"x","deck":"d1","position":1000,"title":"x","deleted_at":""}"#.utf8))
        }
        // New order c,a,b with no current positions -> all three PATCHed with
        // fresh clean gaps 1000,2000,3000 against their own card ids.
        try await (await cardRepo()).reorderCards(deckId: "d1", orderedIds: ["c", "a", "b"])

        let patches = requests(method: "PATCH")
        XCTAssertEqual(patches.count, 3)
        // PATCH target ids match the ordered ids in sequence.
        XCTAssertEqual(patches.map { $0.url?.lastPathComponent }, ["c", "a", "b"])

        let bodies = try allBodies()
        XCTAssertEqual(bodies.count, 3)
        XCTAssertEqual(bodies.compactMap { $0["position"] as? Int }, [1000, 2000, 3000],
                       "reorder must restripe to clean integer gaps")
        // Every reorder body also stamps client_updated_at (shared stamp).
        XCTAssertTrue(bodies.allSatisfy { ($0["client_updated_at"] as? String) == stamp })
    }

    func testReorderOnlyWritesMovedCardWithItsNewPosition() async throws {
        StubURLProtocol.shared.setHandler { _ in
            (200, Data(#"{"id":"x","deck":"d1","position":1000,"title":"x","deleted_at":""}"#.utf8))
        }
        // a stays at 1000 (skip), b moves 1000 -> 2000 (write only b @ 2000).
        try await (await cardRepo()).reorderCards(
            deckId: "d1",
            orderedIds: ["a", "b"],
            currentPositions: ["a": 1000, "b": 1000]
        )
        let patches = requests(method: "PATCH")
        XCTAssertEqual(patches.count, 1)
        XCTAssertEqual(patches.first?.url?.lastPathComponent, "b", "only the moved card is written")
        XCTAssertEqual(try lastBody()["position"] as? Int, 2000)
    }

    // MARK: - Duplicate excludes soft-deleted source cards

    func testDuplicateDeckSourceCardQueryExcludesDeleted() async throws {
        StubURLProtocol.shared.setHandler { request in
            if request.httpMethod == "GET" {
                let url = request.url!.absoluteString
                if url.contains("collections/decks") {
                    return (200, Data(#"{"page":1,"perPage":1,"totalItems":1,"totalPages":1,"items":[{"id":"src","owner":"u","name":"S","shoot_date":"","deleted_at":""}]}"#.utf8))
                }
                // Source card list: stub returns only the live cards (the server
                // would honour the filter); we assert the filter string below.
                return (200, Data(#"{"page":1,"perPage":200,"totalItems":1,"totalPages":1,"items":[{"id":"c_live","deck":"src","position":1000,"title":"Live","deleted_at":""}]}"#.utf8))
            }
            let url = request.url!.absoluteString
            if url.contains("collections/decks") {
                return (200, Data(#"{"id":"copy","owner":"u","name":"S (copy)","deleted_at":""}"#.utf8))
            }
            return (200, Data(#"{"id":"new","deck":"copy","position":1000,"title":"x","deleted_at":""}"#.utf8))
        }

        _ = try await (await deckRepo()).duplicateDeck(id: "src", ownerId: "u")

        // The cards-list GET (the one filtering by deck) must exclude deleted.
        let cardListGet = requests(method: "GET").first {
            ($0.url?.path == "/api/collections/cards/records")
        }
        let comps = URLComponents(url: cardListGet!.url!, resolvingAgainstBaseURL: false)
        let filter = comps?.queryItems?.first { $0.name == "filter" }?.value ?? ""
        XCTAssertEqual(filter, "deck = \"src\" && deleted_at = \"\"",
                       "duplicate must copy only non-soft-deleted source cards")

        // Exactly one card copied (the single live source card), and the copy
        // POST carries deleted_at "" so the duplicate is itself live.
        let copyBodies = try allBodies().filter { $0["deck"] as? String == "copy" }
        XCTAssertEqual(copyBodies.count, 1, "only the live source card is duplicated")
        XCTAssertEqual(copyBodies.first?["title"] as? String, "Live")
        XCTAssertEqual(copyBodies.first?["deleted_at"] as? String, "")
        XCTAssertEqual(copyBodies.first?["position"] as? Int, 1000, "copies get fresh gap positions")
    }

    // MARK: - helpers

    private func lastBody() throws -> [String: Any] {
        let bodies = StubURLProtocol.shared.bodies
        let reqs = StubURLProtocol.shared.requests
        for i in stride(from: bodies.count - 1, through: 0, by: -1) {
            let m = reqs[i].httpMethod
            if (m == "POST" || m == "PATCH"), !bodies[i].isEmpty {
                return try JSONSerialization.jsonObject(with: bodies[i]) as? [String: Any] ?? [:]
            }
        }
        return [:]
    }

    private func allBodies() throws -> [[String: Any]] {
        let bodies = StubURLProtocol.shared.bodies
        let reqs = StubURLProtocol.shared.requests
        var out: [[String: Any]] = []
        for i in bodies.indices {
            let m = reqs[i].httpMethod
            if (m == "POST" || m == "PATCH"), !bodies[i].isEmpty,
               let obj = try JSONSerialization.jsonObject(with: bodies[i]) as? [String: Any] {
                out.append(obj)
            }
        }
        return out
    }
}
