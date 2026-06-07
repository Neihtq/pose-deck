import XCTest
@testable import PoseDeckCore

/// Closes the last iOS-milestone logic gaps the existing core suites leave
/// untested. Each test targets a behaviour with NO prior assertion (verified by
/// reading DeckRepositoryTests, CardRepositoryTests, RepositoryWirePayloadTests,
/// RepositoryPayloadGapTests, RepositoryCoverageGapTests, DeckGroupingTests,
/// DeckGroupingEdgeCaseTests, and PocketBaseDateRoundTripTests):
///
///  - `createCard`'s implicit `listCards` read uses the deck-scoped,
///    soft-delete-excluding filter (the create path's read filter, never pinned).
///  - `createCard` appends after the *max* existing position end-to-end through
///    the POST body (only the pure `nextPosition` helper and an empty-deck create
///    were covered before).
///  - `reorderCards` with an empty ordering issues zero writes (boundary).
///  - `reorderCards` skips *every* card when nothing moved (zero PATCHes).
///  - `reorderCards` PATCH body carries position + client_updated_at and nothing
///    else (it must not re-stamp other card fields under LWW).
///  - `computeReorderedPositions([])` is empty; `nextPosition` handles a deck
///    whose only card sits at a sub-gap / zero position.
///  - `restoredOrder` with an empty snapshot returns the cards sorted by their
///    current positions (defensive no-op-snapshot path).
///  - `duplicateDeck` of an empty source deck issues exactly one create (the
///    deck) and zero card POSTs.
///  - `softDeleteCard` targets `/api/collections/cards/records/{id}` (path pinned
///    for cards' PATCH-only soft-delete, complementing the deck-path tests).
///  - `DeckGrouping.groupDecks` splits a mixed input across all three buckets in
///    a single call, with each bucket internally sorted (the suites covered
///    single-bucket and tie-break cases, not a true 3-way split).
///  - `searchDecks` with a non-matching needle returns empty; matching ignores
///    diacritics-insensitively? (no — pins case-insensitive substring, empty on
///    miss).
///  - `PocketBaseDate.decode` maps a JSON `null` datetime to `nil` (the `null`
///    branch, distinct from the empty-string branch the round-trip suite covers),
///    and `sanitizeEmptyDatetimes` reaches datetime keys nested inside arrays
///    (e.g. PocketBase `expand` payloads).
///
/// All offline: pure helpers or `StubURLProtocol`.
final class RepositoryLogicGapTests: XCTestCase {

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

    // MARK: - createCard's pre-create read uses the deck-scoped live filter

    /// Before computing the next position, `createCard` reads the deck's cards.
    /// That read MUST be scoped to the deck and exclude soft-deleted cards — a
    /// wrong filter would count trashed cards (inflating the position) or read the
    /// whole collection. Only `listCards` (called directly) had this pinned; the
    /// create path's implicit read did not.
    func testCreateCardListReadIsDeckScopedAndExcludesDeleted() async throws {
        StubURLProtocol.shared.setHandler { request in
            if request.httpMethod == "GET" {
                return (200, Data(#"{"page":1,"perPage":200,"totalItems":0,"totalPages":0,"items":[]}"#.utf8))
            }
            return (200, Data(#"{"id":"c","deck":"d77","position":1000,"title":"x","deleted_at":""}"#.utf8))
        }
        _ = try await (await cardRepo()).createCard(deckId: "d77", fields: .init(title: "x"))

        let get = try XCTUnwrap(requests(method: "GET").first, "create must read existing cards first")
        let comps = URLComponents(url: get.url!, resolvingAgainstBaseURL: false)
        let filter = comps?.queryItems?.first { $0.name == "filter" }?.value ?? ""
        XCTAssertEqual(filter, "deck = \"d77\" && deleted_at = \"\"",
                       "create's position read must be deck-scoped and exclude soft-deleted cards")
    }

    /// End-to-end through the POST body: a deck whose existing cards are sparse
    /// (1000, 9000) appends the new card at max+gap (10000), not count*gap — the
    /// create path wires `nextPosition` to the real read, not just the unit test.
    func testCreateCardAppendsAfterMaxPositionInPostBody() async throws {
        StubURLProtocol.shared.setHandler { request in
            if request.httpMethod == "GET" {
                let body = #"""
                {"page":1,"perPage":200,"totalItems":2,"totalPages":1,"items":[
                  {"id":"a","deck":"d1","position":1000,"title":"A","deleted_at":""},
                  {"id":"b","deck":"d1","position":9000,"title":"B","deleted_at":""}
                ]}
                """#
                return (200, Data(body.utf8))
            }
            return (200, Data(#"{"id":"c","deck":"d1","position":10000,"title":"x","deleted_at":""}"#.utf8))
        }
        _ = try await (await cardRepo()).createCard(deckId: "d1", fields: .init(title: "x"))
        XCTAssertEqual(try lastBody()["position"] as? Int, 10000,
                       "new card appends at max(position)+gap, not count*gap")
    }

    // MARK: - reorder boundaries

    /// An empty ordering writes nothing (no cards to restripe).
    func testReorderEmptyOrderingWritesNothing() async throws {
        StubURLProtocol.shared.setHandler { _ in (200, Data("{}".utf8)) }
        try await (await cardRepo()).reorderCards(deckId: "d1", orderedIds: [])
        XCTAssertTrue(requests(method: "PATCH").isEmpty, "no ids -> no PATCHes")
    }

    /// When every card already sits at its computed position, the whole reorder
    /// is a no-op on the wire (skip-all) — a stronger statement than the existing
    /// "skip the one unmoved card" test.
    func testReorderSkipsAllWhenNothingMoved() async throws {
        StubURLProtocol.shared.setHandler { _ in (200, Data("{}".utf8)) }
        try await (await cardRepo()).reorderCards(
            deckId: "d1",
            orderedIds: ["a", "b", "c"],
            currentPositions: ["a": 1000, "b": 2000, "c": 3000]
        )
        XCTAssertTrue(requests(method: "PATCH").isEmpty,
                      "if no card's position changes, the reorder issues zero writes")
    }

    /// A reorder PATCH body must contain ONLY `position` and `client_updated_at`
    /// — re-stamping any other card field would clobber a concurrent field edit
    /// under last-write-wins (ARCHITECTURE.md §4.3).
    func testReorderBodyCarriesOnlyPositionAndStamp() async throws {
        StubURLProtocol.shared.setHandler { _ in
            (200, Data(#"{"id":"a","deck":"d1","position":1000,"title":"x","deleted_at":""}"#.utf8))
        }
        try await (await cardRepo()).reorderCards(deckId: "d1", orderedIds: ["a"])
        let body = try lastBody()
        XCTAssertEqual(body["position"] as? Int, 1000)
        XCTAssertEqual(body["client_updated_at"] as? String, stamp)
        XCTAssertEqual(Set(body.keys), ["position", "client_updated_at"],
                       "reorder must not re-stamp title/notes/etc — only position + client_updated_at")
    }

    // MARK: - pure position-math boundaries

    func testComputeReorderedPositionsEmptyIsEmpty() {
        XCTAssertTrue(CardRepository.computeReorderedPositions(orderedIds: []).isEmpty)
    }

    /// `nextPosition` is `max + gap` even when the only existing card sits at a
    /// non-gap-aligned (or zero) position — it keys off the max, not the count.
    func testNextPositionFromNonAlignedMax() {
        let existing = [Card(id: "a", deck: "d1", position: 0, title: "A"),
                        Card(id: "b", deck: "d1", position: 250, title: "B")]
        XCTAssertEqual(CardRepository.nextPosition(after: existing), 1250)
    }

    /// `restoredOrder` with an empty snapshot leaves every position untouched and
    /// returns the cards sorted by their current position (defensive path: no
    /// pre-drag info means "trust current positions").
    func testRestoredOrderEmptySnapshotSortsByCurrentPosition() {
        let cards = [
            Card(id: "c", deck: "d1", position: 3000, title: "C"),
            Card(id: "a", deck: "d1", position: 1000, title: "A"),
            Card(id: "b", deck: "d1", position: 2000, title: "B"),
        ]
        let restored = CardRepository.restoredOrder(of: cards, to: [:])
        XCTAssertEqual(restored.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(restored.map(\.position), [1000, 2000, 3000])
    }

    // MARK: - duplicate of an empty deck

    /// Duplicating a deck with no live cards creates exactly one record (the copy
    /// deck) and zero card POSTs — the copy loop must not run for an empty source.
    func testDuplicateEmptyDeckCreatesOnlyTheCopyDeck() async throws {
        StubURLProtocol.shared.setHandler { request in
            if request.httpMethod == "GET" {
                let url = request.url!.absoluteString
                if url.contains("collections/decks") {
                    return (200, Data(#"{"page":1,"perPage":1,"totalItems":1,"totalPages":1,"items":[{"id":"src","owner":"u","name":"Empty","shoot_date":"","deleted_at":""}]}"#.utf8))
                }
                return (200, Data(#"{"page":1,"perPage":200,"totalItems":0,"totalPages":0,"items":[]}"#.utf8))
            }
            return (200, Data(#"{"id":"copy","owner":"u","name":"Empty (copy)","deleted_at":""}"#.utf8))
        }
        _ = try await (await deckRepo()).duplicateDeck(id: "src", ownerId: "u")

        let posts = requests(method: "POST")
        XCTAssertEqual(posts.count, 1, "an empty source duplicates into exactly one create (the deck)")
        XCTAssertEqual(posts.first?.url?.path, "/api/collections/decks/records",
                       "the single create targets the decks collection")
    }

    // MARK: - softDeleteCard path

    /// `softDeleteCard` PATCHes the cards collection by id (path pinned, mirroring
    /// the deck soft-delete path test). A path typo would soft-delete the wrong
    /// record class.
    func testSoftDeleteCardTargetsCardsRecordPath() async throws {
        StubURLProtocol.shared.setHandler { _ in
            (200, Data(#"{"id":"c5","deck":"d1","position":1000,"title":"x","deleted_at":"2023-11-14 22:13:20.000Z"}"#.utf8))
        }
        _ = try await (await cardRepo()).softDeleteCard(id: "c5")
        let patches = requests(method: "PATCH")
        XCTAssertEqual(patches.count, 1)
        XCTAssertEqual(patches.first?.url?.path, "/api/collections/cards/records/c5")
    }

    // MARK: - DeckGrouping 3-way split in a single call

    /// A mixed input splits across all three buckets at once, each internally
    /// sorted: upcoming soonest-first, past most-recent-first, undated by name.
    func testGroupDecksSplitsAcrossAllThreeBucketsSorted() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        func d(_ y: Int, _ m: Int, _ day: Int) -> Date {
            var c = DateComponents(); c.year = y; c.month = m; c.day = day; c.hour = 12
            return cal.date(from: c)!
        }
        let now = d(2026, 6, 6)
        let decks = [
            Deck(id: "soon", owner: "u", name: "Soon", shootDate: d(2026, 6, 10)),
            Deck(id: "later", owner: "u", name: "Later", shootDate: d(2026, 9, 1)),
            Deck(id: "zzz", owner: "u", name: "Zulu"),
            Deck(id: "aaa", owner: "u", name: "alpha"),
            Deck(id: "recent", owner: "u", name: "Recent", shootDate: d(2026, 5, 1)),
            Deck(id: "old", owner: "u", name: "Old", shootDate: d(2025, 1, 1)),
        ]
        let g = DeckGrouping.groupDecks(decks, now: now, calendar: cal)
        XCTAssertEqual(g.upcoming.map(\.id), ["soon", "later"], "upcoming soonest-first")
        XCTAssertEqual(g.past.map(\.id), ["recent", "old"], "past most-recent-first")
        XCTAssertEqual(g.undated.map(\.id), ["aaa", "zzz"], "undated case-insensitive by name")
    }

    // MARK: - search miss returns empty

    func testSearchReturnsEmptyWhenNoMatch() {
        let decks = [
            Deck(id: "a", owner: "u", name: "Beach sunset"),
            Deck(id: "b", owner: "u", name: "Studio"),
        ]
        XCTAssertTrue(DeckGrouping.searchDecks(decks, query: "mountain").isEmpty,
                      "a needle matching no deck name yields an empty result")
    }

    // MARK: - PocketBaseDate null branch + nested-array sanitize

    /// A JSON `null` at a datetime key decodes to `nil` (the `null`-unset branch,
    /// distinct from the empty-string-unset branch). PocketBase emits `null` as
    /// well as `""` for an unset datetime, per the type docs.
    func testNullDatetimeDecodesToNil() throws {
        let json = #"{"id":"d1","owner":"u","name":"X","shoot_date":null,"deleted_at":null}"#
        let deck = try PocketBaseDate.decode(Deck.self, from: Data(json.utf8))
        XCTAssertNil(deck.shootDate, "a null datetime is unset -> nil")
        XCTAssertNil(deck.deletedAt)
    }

    /// `sanitizeEmptyDatetimes` must reach datetime keys nested inside arrays
    /// (e.g. PocketBase `expand`-style nested records), not just top-level keys —
    /// otherwise an empty-string datetime inside an array element would throw on
    /// decode instead of decoding to nil.
    func testSanitizeReachesDatetimeKeysInsideArrays() throws {
        let json = #"""
        {"page":1,"perPage":200,"totalItems":1,"totalPages":1,"items":[
          {"id":"c1","deck":"d1","position":1000,"title":"T","deleted_at":""}
        ]}
        """#
        // Decode the envelope's items array; the nested empty deleted_at must
        // have been sanitized so the Card decodes with deletedAt == nil.
        struct Envelope: Decodable { let items: [Card] }
        let env = try PocketBaseDate.decode(Envelope.self, from: Data(json.utf8))
        XCTAssertEqual(env.items.count, 1)
        XCTAssertNil(env.items.first?.deletedAt,
                     "empty-string datetime nested in an array element must sanitize to nil, not throw")
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
}
