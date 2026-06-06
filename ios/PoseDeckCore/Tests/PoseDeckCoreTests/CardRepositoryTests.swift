import XCTest
@testable import PoseDeckCore

/// Tests for `CardRepository` position math and mutation bodies, exercised
/// offline via `StubURLProtocol`.
final class CardRepositoryTests: XCTestCase {

    override func tearDown() {
        StubURLProtocol.shared.reset()
        super.tearDown()
    }

    private func card(_ id: String, position: Int) -> Card {
        Card(id: id, deck: "d1", position: position, title: id)
    }

    private func makeClient() async -> APIClient {
        let client = APIClient(baseURL: URL(string: "http://stub.local")!, session: StubURLProtocol.makeSession())
        await client.setAuthToken("test-token")
        return client
    }

    private static let fixedNow = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14 22:13:20 UTC
    private var fixedNow: Date { Self.fixedNow }

    // MARK: - Pure position math

    func testNextPositionEmptyDeck() {
        XCTAssertEqual(CardRepository.nextPosition(after: []), 1000)
    }

    func testNextPositionAppendsGapAfterMax() {
        let existing = [card("a", position: 1000), card("b", position: 2000)]
        XCTAssertEqual(CardRepository.nextPosition(after: existing), 3000)
    }

    func testNextPositionUsesMaxNotCount() {
        // Out-of-order / sparse positions: must be max + gap, not count-based.
        let existing = [card("a", position: 5000), card("b", position: 1000)]
        XCTAssertEqual(CardRepository.nextPosition(after: existing), 6000)
    }

    func testComputeReorderedPositionsRestripesGaps() {
        let result = CardRepository.computeReorderedPositions(orderedIds: ["c", "a", "b"])
        XCTAssertEqual(result.map(\.id), ["c", "a", "b"])
        XCTAssertEqual(result.map(\.position), [1000, 2000, 3000])
    }

    // MARK: - restoredOrder (CORR-3 regression)

    /// Regression for CORR-3: a mid-loop reorder failure leaves a partial server
    /// write (some cards restriped, some not), so reloading surfaces a
    /// neither-old-nor-new ordering. `restoredOrder` re-applies the captured
    /// pre-drag positions locally so the list reverts to exactly its pre-drag
    /// order, recovering from the partial apply.
    func testRestoredOrderRevertsPartialReorderToPreDragOrder() {
        // Pre-drag order: a(1000), b(2000), c(3000).
        let before: [String: Int] = ["a": 1000, "b": 2000, "c": 3000]

        // User dragged c to the front -> optimistic local order [c, a, b].
        // reorderCards restripes c to 1000 on the server, then the PATCH for the
        // next card fails. The local `cards` still reflect the optimistic order,
        // but one card (c) carries its newly-written position.
        let optimistic = [
            card("c", position: 1000), // already restriped on the server
            card("a", position: 1000), // computed new position not yet written
            card("b", position: 2000),
        ]

        let restored = CardRepository.restoredOrder(of: optimistic, to: before)

        // Must be back to the pre-drag order a, b, c with pre-drag positions —
        // NOT the scrambled [c, a, b] the server would now report.
        XCTAssertEqual(restored.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(restored.map(\.position), [1000, 2000, 3000])
    }

    /// Cards absent from the snapshot keep their current position and still sort
    /// deterministically (defensive: a card created mid-drag has no pre-drag pos).
    func testRestoredOrderKeepsUnknownCardsCurrentPosition() {
        let before: [String: Int] = ["a": 1000, "b": 2000]
        let cards = [
            card("b", position: 1000),
            card("a", position: 2000),
            card("z", position: 5000), // not in snapshot
        ]
        let restored = CardRepository.restoredOrder(of: cards, to: before)
        XCTAssertEqual(restored.map(\.id), ["a", "b", "z"])
        XCTAssertEqual(restored.map(\.position), [1000, 2000, 5000])
    }

    // MARK: - createCard against the stub

    func testCreateCardComputesNextPositionAndStampsClientUpdatedAt() async throws {
        // First GET (listCards) returns two existing cards; POST echoes a card.
        StubURLProtocol.shared.setHandler { request in
            if request.httpMethod == "GET" {
                let body = """
                {"page":1,"perPage":200,"totalItems":2,"totalPages":1,"items":[
                  {"id":"a","deck":"d1","position":1000,"title":"A","deleted_at":""},
                  {"id":"b","deck":"d1","position":2000,"title":"B","deleted_at":""}
                ]}
                """
                return (200, Data(body.utf8))
            }
            // POST: echo a created card.
            return (200, Data(#"{"id":"c","deck":"d1","position":3000,"title":"C","deleted_at":""}"#.utf8))
        }

        let repo = CardRepository(client: await makeClient(), now: { Self.fixedNow })
        let created = try await repo.createCard(deckId: "d1", fields: .init(title: "C"))
        XCTAssertEqual(created.position, 3000)

        // Inspect the POST body: position 3000, client_updated_at stamped in PB format.
        let postBody = try lastPostBody()
        XCTAssertEqual(postBody["position"] as? Int, 3000)
        XCTAssertEqual(postBody["client_updated_at"] as? String,
                       PocketBaseDate.string(from: fixedNow))
        XCTAssertEqual(postBody["deleted_at"] as? String, "")
    }

    func testCreateCardClampsTitleTo60() async throws {
        StubURLProtocol.shared.setHandler { request in
            if request.httpMethod == "GET" {
                return (200, Data(#"{"page":1,"perPage":200,"totalItems":0,"totalPages":0,"items":[]}"#.utf8))
            }
            return (200, Data(#"{"id":"c","deck":"d1","position":1000,"title":"x","deleted_at":""}"#.utf8))
        }
        let longTitle = String(repeating: "a", count: 100)
        let repo = CardRepository(client: await makeClient(), now: { Self.fixedNow })
        _ = try await repo.createCard(deckId: "d1", fields: .init(title: longTitle))

        let postBody = try lastPostBody()
        XCTAssertEqual((postBody["title"] as? String)?.count, 60, "title must be clamped to 60 chars")
    }

    // MARK: - listCards pagination (CORR-2 regression)

    /// Regression for CORR-2: a deck with more than one page of cards must NOT be
    /// truncated to the first page. `listCards` walks every page via `listAll`
    /// (mirrors the web `getFullList`), so all records are returned in order.
    func testListCardsFetchesEveryPage() async throws {
        let perPage = 200
        // Two full pages + a short final page -> 450 cards across 3 pages.
        let total = 450
        let totalPages = 3

        StubURLProtocol.shared.setHandler { request in
            guard request.httpMethod == "GET" else { return (200, Data("{}".utf8)) }
            let comps = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
            let page = Int(comps?.queryItems?.first(where: { $0.name == "page" })?.value ?? "1") ?? 1
            let start = (page - 1) * perPage
            let end = min(start + perPage, total)
            let items = (start..<end).map { i in
                #"{"id":"c\#(i)","deck":"d1","position":\#((i + 1) * 1000),"title":"C\#(i)","deleted_at":""}"#
            }.joined(separator: ",")
            let body = #"{"page":\#(page),"perPage":\#(perPage),"totalItems":\#(total),"totalPages":\#(totalPages),"items":[\#(items)]}"#
            return (200, Data(body.utf8))
        }

        let repo = CardRepository(client: await makeClient(), now: { Self.fixedNow })
        let cards = try await repo.listCards(deckId: "d1")

        XCTAssertEqual(cards.count, total, "all cards across every page must be returned, not just the first 200")
        XCTAssertEqual(cards.first?.id, "c0")
        XCTAssertEqual(cards.last?.id, "c449", "records beyond the first page must not be dropped")

        let getRequests = StubURLProtocol.shared.requests.filter { $0.httpMethod == "GET" }
        XCTAssertEqual(getRequests.count, totalPages, "should issue one GET per page")
    }

    // MARK: - reorderCards skip logic

    func testReorderSkipsUnmovedCards() async throws {
        StubURLProtocol.shared.setHandler { _ in
            (200, Data(#"{"id":"x","deck":"d1","position":1000,"title":"x","deleted_at":""}"#.utf8))
        }
        let repo = CardRepository(client: await makeClient(), now: { Self.fixedNow })
        // a already at 1000 (== its computed new position) -> skipped.
        // b moves from 1000 to 2000 -> written.
        try await repo.reorderCards(
            deckId: "d1",
            orderedIds: ["a", "b"],
            currentPositions: ["a": 1000, "b": 1000]
        )
        let patchRequests = StubURLProtocol.shared.requests.filter { $0.httpMethod == "PATCH" }
        XCTAssertEqual(patchRequests.count, 1, "only the moved card should be PATCHed")
    }

    func testReorderWritesAllWhenNoCurrentPositions() async throws {
        StubURLProtocol.shared.setHandler { _ in
            (200, Data(#"{"id":"x","deck":"d1","position":1000,"title":"x","deleted_at":""}"#.utf8))
        }
        let repo = CardRepository(client: await makeClient(), now: { Self.fixedNow })
        try await repo.reorderCards(deckId: "d1", orderedIds: ["a", "b", "c"])
        let patchRequests = StubURLProtocol.shared.requests.filter { $0.httpMethod == "PATCH" }
        XCTAssertEqual(patchRequests.count, 3)
    }

    // MARK: - softDeleteCard stamps both fields

    func testSoftDeleteSetsDeletedAtAndClientUpdatedAt() async throws {
        StubURLProtocol.shared.setHandler { _ in
            (200, Data(#"{"id":"a","deck":"d1","position":1000,"title":"A","deleted_at":"2023-11-14 22:13:20.000Z"}"#.utf8))
        }
        let repo = CardRepository(client: await makeClient(), now: { Self.fixedNow })
        _ = try await repo.softDeleteCard(id: "a")

        let body = try lastPostBody()
        let stamp = PocketBaseDate.string(from: fixedNow)
        XCTAssertEqual(body["deleted_at"] as? String, stamp)
        XCTAssertEqual(body["client_updated_at"] as? String, stamp)
    }

    // MARK: - helpers

    /// Parse the most recent request body (POST/PATCH) as a JSON object.
    private func lastPostBody() throws -> [String: Any] {
        let bodies = StubURLProtocol.shared.bodies
        let requests = StubURLProtocol.shared.requests
        for i in stride(from: bodies.count - 1, through: 0, by: -1) {
            let method = requests[i].httpMethod
            if method == "POST" || method == "PATCH", !bodies[i].isEmpty {
                return try JSONSerialization.jsonObject(with: bodies[i]) as? [String: Any] ?? [:]
            }
        }
        return [:]
    }
}
