import XCTest
@testable import PoseDeckCore

/// Coverage for the network ``CardCompletionRepository`` (A6 / ARCHITECTURE.md
/// §3.6): the backfill list filter scopes to the user, writes use the
/// deterministic id, and an upsert falls back to a state PATCH on a
/// composite-unique collision. Exercised fully offline via ``StubURLProtocol``.
final class CardCompletionRepositoryTests: XCTestCase {

    private static let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

    override func tearDown() {
        StubURLProtocol.shared.reset()
        super.tearDown()
    }

    private func makeRepo() async -> CardCompletionRepository {
        let client = APIClient(baseURL: URL(string: "http://stub.local")!, session: StubURLProtocol.makeSession())
        await client.setAuthToken("tok")
        return CardCompletionRepository(client: client, now: { Self.fixedNow })
    }

    private func lastGetQuery() -> [String: String] {
        let gets = StubURLProtocol.shared.requests.filter { $0.httpMethod == "GET" }
        guard let url = gets.last?.url,
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return [:] }
        var out: [String: String] = [:]
        for item in comps.queryItems ?? [] { out[item.name] = item.value }
        return out
    }

    func testListCompletionsFiltersByUserAndTargetsCollection() async throws {
        StubURLProtocol.shared.setHandler { _ in
            (200, Data(#"{"page":1,"perPage":200,"totalItems":0,"totalPages":1,"items":[]}"#.utf8))
        }
        _ = try await (await makeRepo()).listCompletions(forUser: "user01")
        let get = StubURLProtocol.shared.requests.first { $0.httpMethod == "GET" }
        XCTAssertEqual(get?.url?.path, "/api/collections/card_completions/records")
        XCTAssertEqual(lastGetQuery()["filter"], "user = \"user01\"")
    }

    func testMarkDoneCreatesWithDeterministicIdAndFullBody() async throws {
        let expectedId = CardCompletion.deterministicId(card: "card01", user: "user01")
        StubURLProtocol.shared.setHandler { _ in
            (200, Data(#"{"id":"\#(expectedId)","card":"card01","user":"user01","state":"done","changed_at":"2026-06-07 12:00:00.000Z"}"#.utf8))
        }
        let result = try await (await makeRepo()).markDone(cardId: "card01", userId: "user01")
        XCTAssertEqual(result.id, expectedId)

        let post = StubURLProtocol.shared.requests.first { $0.httpMethod == "POST" }
        XCTAssertEqual(post?.url?.path, "/api/collections/card_completions/records")
        let body = (try? JSONSerialization.jsonObject(with: StubURLProtocol.shared.bodies.first ?? Data())) as? [String: Any]
        XCTAssertEqual(body?["id"] as? String, expectedId)
        XCTAssertEqual(body?["card"] as? String, "card01")
        XCTAssertEqual(body?["user"] as? String, "user01")
        XCTAssertEqual(body?["state"] as? String, "done")
    }

    func testUpsertFallsBackToPatchOnUniqueCollision() async throws {
        let expectedId = CardCompletion.deterministicId(card: "card01", user: "user01")
        StubURLProtocol.shared.setHandler { request in
            if request.httpMethod == "POST" {
                return (400, Data(#"{"data":{"id":{"code":"validation_not_unique","message":"x"}}}"#.utf8))
            }
            return (200, Data(#"{"id":"\#(expectedId)","card":"card01","user":"user01","state":"skipped","changed_at":"2026-06-07 12:00:00.000Z"}"#.utf8))
        }
        let result = try await (await makeRepo()).markSkipped(cardId: "card01", userId: "user01")
        XCTAssertEqual(result.state, .skipped)

        let methods = StubURLProtocol.shared.requests.map(\.httpMethod)
        XCTAssertEqual(methods, ["POST", "PATCH"], "create collides → PATCH the existing row")
        let patch = StubURLProtocol.shared.requests.last
        XCTAssertEqual(patch?.url?.path, "/api/collections/card_completions/records/\(expectedId)")
    }
}
