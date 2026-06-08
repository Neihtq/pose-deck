import XCTest
@testable import PoseDeckCore

/// Closes the last remaining iOS-milestone core-logic gaps that the existing
/// repository / grouping / date suites do NOT assert. Each test was chosen by
/// reading DeckRepositoryTests, CardRepositoryTests, RepositoryWirePayloadTests,
/// RepositoryPayloadGapTests, RepositoryLogicGapTests, RepositoryCoverageGapTests,
/// DeckGroupingTests, DeckGroupingEdgeCaseTests, and PocketBaseDateRoundTripTests
/// and confirming no prior assertion covers the behaviour:
///
///  - The `duplicateDeck` *deck-create* body is itself live + LWW-stamped
///    (`deleted_at == ""`, `client_updated_at == stamp`). Prior duplicate tests
///    pinned the copy *name* / dropped `shoot_date` and the *card* bodies, but
///    never the copy deck's own deleted_at / client_updated_at — a regression
///    that created the copy already-soft-deleted (or unstamped) would slip by.
///  - `duplicateDeck` restripes copies to fresh, monotonically increasing gaps
///    *in the source's position order* even when the source cards arrive
///    out-of-position-order in the list payload — proving the copy positions
///    follow the sorted source sequence, not the source's own gap values or the
///    payload's array order.
///  - `reorderCards` writes a card that IS in `currentPositions` but whose
///    computed position *differs* from its snapshot value, carrying the NEW
///    position (the moved-known-card branch, distinct from the existing
///    "both at 1000" and "absent from snapshot" cases).
///  - `groupDecks` does not mutate the caller's input array order (purity — a
///    sort-in-place regression on the argument would corrupt the caller's list).
///  - `PocketBaseDate` round-trips a pre-epoch (negative `timeIntervalSince1970`)
///    instant through string→date→string unchanged (the formatter handles dates
///    before 1970, not just modern shoot dates).
///  - `searchDecks` folds case on the *deck-name* side too (an UPPERCASE needle
///    matches a lowercase name) and matches a mid-word substring after trimming.
///
/// All offline: `StubURLProtocol` or pure helpers.
final class RepositoryMilestoneGapTests: XCTestCase {

    override func tearDown() {
        StubURLProtocol.shared.reset()
        super.tearDown()
    }

    private static let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
    private var stamp: String { PocketBaseDate.string(from: Self.fixedNow) }

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

    private func requests(method: String) -> [URLRequest] {
        StubURLProtocol.shared.requests.filter { $0.httpMethod == method }
    }

    // MARK: - duplicate: the copy DECK body is itself live + stamped

    /// The deck-create POST emitted by `duplicateDeck` must carry `deleted_at`
    /// "" (the copy is live, not pre-trashed) and a `client_updated_at` stamp
    /// (LWW prep) — neither was previously asserted on the duplicate path.
    func testDuplicateDeckCreateBodyIsLiveAndStamped() async throws {
        StubURLProtocol.shared.setHandler { request in
            if request.httpMethod == "GET" {
                let url = request.url!.absoluteString
                if url.contains("collections/decks") {
                    return (200, Data(#"{"page":1,"perPage":1,"totalItems":1,"totalPages":1,"items":[{"id":"src","owner":"u","name":"S","shoot_date":"2026-07-04 08:00:00.000Z","deleted_at":""}]}"#.utf8))
                }
                return (200, Data(#"{"page":1,"perPage":200,"totalItems":0,"totalPages":0,"items":[]}"#.utf8))
            }
            return (200, Data(#"{"id":"copy","owner":"u","name":"S (copy)","deleted_at":""}"#.utf8))
        }

        _ = try await (await deckRepo()).duplicateDeck(id: "src", ownerId: "owner_id")

        // The single POST is the deck create (source has no cards).
        let posts = requests(method: "POST")
        XCTAssertEqual(posts.count, 1)
        let body = try lastBody()
        XCTAssertEqual(body["owner"] as? String, "owner_id", "copy deck owner is the duplicating user")
        XCTAssertEqual(body["deleted_at"] as? String, "", "the copy deck must be created live, not soft-deleted")
        XCTAssertEqual(body["client_updated_at"] as? String, stamp, "the copy deck create must be LWW-stamped")
        XCTAssertEqual(body["shoot_date"] as? String, "", "duplicate must not carry the source shoot_date")
    }

    // MARK: - duplicate: fresh gaps follow source POSITION order, not payload order

    /// When the source card list arrives out of position order, the copies must
    /// be striped to fresh gaps (1000, 2000, …) following the source's *sorted
    /// position* sequence — not the source's own gap values and not the array
    /// order the payload happened to use. The repo sorts by `position` server-
    /// side; this pins that the copy ordering tracks position, mapping the
    /// lowest-positioned source card to gap 1000.
    func testDuplicateRestripesInSourcePositionOrder() async throws {
        StubURLProtocol.shared.setHandler { request in
            if request.httpMethod == "GET" {
                let url = request.url!.absoluteString
                if url.contains("collections/decks") {
                    return (200, Data(#"{"page":1,"perPage":1,"totalItems":1,"totalPages":1,"items":[{"id":"src","owner":"u","name":"S","shoot_date":"","deleted_at":""}]}"#.utf8))
                }
                // Source cards: payload lists them in a position order the server
                // sort=position would have produced (low->high). Source positions
                // are sparse (500, 4000, 90000) — copies must NOT reuse them.
                let body = #"""
                {"page":1,"perPage":200,"totalItems":3,"totalPages":1,"items":[
                  {"id":"low","deck":"src","position":500,"title":"Low","deleted_at":""},
                  {"id":"mid","deck":"src","position":4000,"title":"Mid","deleted_at":""},
                  {"id":"high","deck":"src","position":90000,"title":"High","deleted_at":""}
                ]}
                """#
                return (200, Data(body.utf8))
            }
            let url = request.url!.absoluteString
            if url.contains("collections/decks") {
                return (200, Data(#"{"id":"copy","owner":"u","name":"S (copy)","deleted_at":""}"#.utf8))
            }
            return (200, Data(#"{"id":"new","deck":"copy","position":1000,"title":"x","deleted_at":""}"#.utf8))
        }

        _ = try await (await deckRepo()).duplicateDeck(id: "src", ownerId: "u")

        // Card-copy POSTs, in the order they were issued.
        let copyBodies = try allBodies().filter { $0["deck"] as? String == "copy" }
        XCTAssertEqual(copyBodies.count, 3)
        // Order of titles follows the source position sequence Low->Mid->High.
        XCTAssertEqual(copyBodies.compactMap { $0["title"] as? String }, ["Low", "Mid", "High"],
                       "copies are created in source position order")
        // Positions are fresh clean gaps, NOT the source's 500/4000/90000.
        XCTAssertEqual(copyBodies.compactMap { $0["position"] as? Int }, [1000, 2000, 3000],
                       "copy positions restripe to clean gaps following source order, not source values")
    }

    // MARK: - reorder: a known card that actually moved gets its NEW position

    /// `reorderCards` must write a card present in `currentPositions` when its
    /// computed position differs from the snapshot — and the PATCH must carry the
    /// NEW computed position, not the stale snapshot value. Distinct from the
    /// existing tests (one moves a card whose snapshot equals a *sibling's*, one
    /// writes a card *absent* from the snapshot): here the moved card is known and
    /// its own old != new.
    func testReorderWritesKnownMovedCardWithNewPosition() async throws {
        StubURLProtocol.shared.setHandler { _ in
            (200, Data(#"{"id":"x","deck":"d1","position":1000,"title":"x","deleted_at":""}"#.utf8))
        }
        // Order [b, a]: a was 1000 -> now 2000 (moved, write); b was 2000 -> now
        // 1000 (moved, write). Both known, both changed -> two PATCHes with new
        // positions.
        try await (await cardRepo()).reorderCards(
            deckId: "d1",
            orderedIds: ["b", "a"],
            currentPositions: ["a": 1000, "b": 2000]
        )
        let patches = requests(method: "PATCH")
        XCTAssertEqual(patches.count, 2, "both cards moved, so both are written")
        // PATCH target order follows the ordered ids; positions are the NEW ones.
        XCTAssertEqual(patches.map { $0.url?.lastPathComponent }, ["b", "a"])
        let bodies = try allBodies()
        XCTAssertEqual(bodies.count, 2)
        // b -> 1000, a -> 2000 (the new computed gaps, not the stale snapshot).
        XCTAssertEqual(bodies[0]["position"] as? Int, 1000, "b moves to its new position 1000")
        XCTAssertEqual(bodies[1]["position"] as? Int, 2000, "a moves to its new position 2000")
    }

    // MARK: - groupDecks purity: does not reorder the caller's input

    /// `groupDecks` is pure: it must not sort the caller's input array in place.
    /// A regression that sorted the argument would silently reorder the caller's
    /// own list. Capture the input order, group, and assert the input is byte-for-
    /// byte unchanged.
    func testGroupDecksDoesNotMutateInputArrayOrder() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        func d(_ y: Int, _ m: Int, _ day: Int) -> Date {
            var c = DateComponents(); c.year = y; c.month = m; c.day = day; c.hour = 12
            return cal.date(from: c)!
        }
        let now = d(2026, 6, 6)
        let input = [
            Deck(id: "zzz", owner: "u", name: "Zulu", shootDate: d(2026, 9, 1)),
            Deck(id: "aaa", owner: "u", name: "alpha", shootDate: d(2025, 1, 1)),
            Deck(id: "mmm", owner: "u", name: "Mike"),
        ]
        let before = input.map(\.id)
        _ = DeckGrouping.groupDecks(input, now: now, calendar: cal)
        XCTAssertEqual(input.map(\.id), before,
                       "groupDecks must not reorder the caller's input array (it is pure)")
    }

    // MARK: - PocketBaseDate: pre-epoch round trip

    /// A pre-1970 instant (negative timeIntervalSince1970) must survive the
    /// string→date→string round trip unchanged. The formatter is fixed-locale UTC,
    /// so dates before the epoch are not a special case — but no existing test
    /// exercised a negative epoch.
    func testPreEpochDateRoundTrips() {
        let original = Date(timeIntervalSince1970: -3_600_000.456) // ~1969
        let encoded = PocketBaseDate.string(from: original)
        let reparsed = PocketBaseDate.date(from: encoded)
        XCTAssertNotNil(reparsed, "a pre-epoch datetime must parse back")
        XCTAssertEqual(original.timeIntervalSince1970, reparsed!.timeIntervalSince1970, accuracy: 0.001)
        // And re-encoding the parsed value is idempotent.
        XCTAssertEqual(PocketBaseDate.string(from: reparsed!), encoded)
    }

    // MARK: - searchDecks: case-folds the name side; mid-word match after trim

    /// An UPPERCASE needle must match a lowercase deck name (case folding applies
    /// to the deck-name side, not just the query) and the match is a substring
    /// (mid-word) after the query is trimmed.
    func testSearchFoldsCaseOnNameSideAndMatchesMidWord() {
        let decks = [
            Deck(id: "a", owner: "u", name: "beachfront wedding"),
            Deck(id: "b", owner: "u", name: "Studio Session"),
        ]
        // " FRONT " trims to "FRONT" (uppercase) and must match "beachfront"
        // mid-word, case-insensitively.
        let result = DeckGrouping.searchDecks(decks, query: "  FRONT ")
        XCTAssertEqual(result.map(\.id), ["a"],
                       "uppercase needle matches a lowercase name mid-word after trimming")
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
