import XCTest
@testable import PoseDeckCore

/// Fills coverage gaps in the iOS milestone repository / grouping / date logic
/// that the existing suites leave untested:
///  - `CardRepository.updateCard` clamps the title to 60 chars (only the
///    *create* clamp was previously covered).
///  - `DeckRepository.duplicateDeck` propagates `notFound` when the source deck
///    is trashed/missing (the soft-delete-aware `getDeck` makes a trashed source
///    read as not-found — the docstring promises this, but it was untested).
///  - `CardRepository.reorderCards` always writes a card *absent* from the
///    `currentPositions` snapshot (the "ids absent from the map are always
///    written" rule, mixed with skipping an unmoved known card).
///  - `PocketBaseDate.date(from:)` parses the millis-bearing `T`-separated ISO
///    fallback (only the fractionless ISO form was previously covered).
///  - `DeckGrouping.searchDecks` returns the input unchanged for a no-needle
///    query (identity, not merely "same ids").
///
/// All offline: pure helpers or `StubURLProtocol`.
final class RepositoryCoverageGapTests: XCTestCase {

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

    // MARK: - updateCard title clamp (CardRepository.swift line ~163)

    /// `updateCard` clamps an over-long title to the 60-char product cap
    /// (DESIGN.md §3). The create path was already covered; the PATCH path was
    /// not — its own `String($0.prefix(titleMaxLength))` clamp is exercised here.
    func testUpdateCardClampsTitleTo60() async throws {
        StubURLProtocol.shared.setHandler { _ in
            (200, Data(#"{"id":"c1","deck":"d1","position":1000,"title":"x","deleted_at":""}"#.utf8))
        }
        let repo = CardRepository(client: await makeClient(), now: { Self.fixedNow })
        let longTitle = String(repeating: "z", count: 120)
        _ = try await repo.updateCard(id: "c1", fields: .init(title: longTitle))

        let body = try lastBody()
        XCTAssertEqual((body["title"] as? String)?.count, CardRepository.titleMaxLength,
                       "updateCard must clamp the title to 60 chars on the PATCH path too")
        XCTAssertEqual(body["client_updated_at"] as? String, stamp)
    }

    /// A title at or under the cap is written verbatim (no truncation regressions
    /// for normal-length edits).
    func testUpdateCardLeavesShortTitleUnchanged() async throws {
        StubURLProtocol.shared.setHandler { _ in
            (200, Data(#"{"id":"c1","deck":"d1","position":1000,"title":"x","deleted_at":""}"#.utf8))
        }
        let repo = CardRepository(client: await makeClient(), now: { Self.fixedNow })
        _ = try await repo.updateCard(id: "c1", fields: .init(title: "Golden hour"))
        XCTAssertEqual(try lastBody()["title"] as? String, "Golden hour")
    }

    // MARK: - duplicateDeck not-found propagation

    /// Duplicating a trashed/missing deck must surface `notFound`, not silently
    /// create an empty copy: `getDeck` excludes soft-deleted records, so a
    /// trashed source reads as absent and `duplicateDeck` rethrows. Also asserts
    /// NO create POST is issued when the source is not found.
    func testDuplicateDeckThrowsNotFoundForMissingSource() async throws {
        StubURLProtocol.shared.setHandler { _ in
            // getDeck list query returns an empty envelope (source not live).
            (200, Data(#"{"page":1,"perPage":1,"totalItems":0,"totalPages":0,"items":[]}"#.utf8))
        }
        let repo = DeckRepository(client: await makeClient(), now: { Self.fixedNow })
        do {
            _ = try await repo.duplicateDeck(id: "trashed", ownerId: "u")
            XCTFail("expected notFound for a trashed/missing source deck")
        } catch let DeckRepositoryError.notFound(id) {
            XCTAssertEqual(id, "trashed")
        }
        // Nothing must have been created when the source is not found.
        let posts = StubURLProtocol.shared.requests.filter { $0.httpMethod == "POST" }
        XCTAssertTrue(posts.isEmpty, "no copy must be created when the source deck is not found")
    }

    // MARK: - reorder always writes cards absent from the snapshot

    /// `reorderCards` skips a known unmoved card but still writes a card that is
    /// *absent* from `currentPositions` (e.g. created mid-drag): "ids absent from
    /// the map are always written".
    func testReorderWritesCardAbsentFromCurrentPositions() async throws {
        StubURLProtocol.shared.setHandler { _ in
            (200, Data(#"{"id":"x","deck":"d1","position":1000,"title":"x","deleted_at":""}"#.utf8))
        }
        let repo = CardRepository(client: await makeClient(), now: { Self.fixedNow })
        // a is known and already at its computed position 1000 -> skipped.
        // b is NOT in the snapshot -> must be written even though its computed
        // position (2000) might coincide with nothing we can compare against.
        try await repo.reorderCards(
            deckId: "d1",
            orderedIds: ["a", "b"],
            currentPositions: ["a": 1000]
        )
        let patches = StubURLProtocol.shared.requests.filter { $0.httpMethod == "PATCH" }
        XCTAssertEqual(patches.count, 1, "the absent-from-snapshot card must be written; the known unmoved one skipped")
        XCTAssertEqual(patches.first?.url?.lastPathComponent, "b",
                       "only the card absent from the snapshot is written")
        XCTAssertEqual(try lastBody()["position"] as? Int, 2000)
    }

    // MARK: - PocketBaseDate millis-bearing ISO `T` fallback

    /// The `T`-separated ISO form *with* milliseconds must parse via the
    /// `makeISOFormatter` fallback. Only the fractionless ISO form was covered;
    /// this pins the millis-bearing branch.
    func testParsesMillisBearingISODateString() {
        let raw = "2026-07-04T08:00:00.000Z"
        let date = PocketBaseDate.date(from: raw)
        XCTAssertNotNil(date, "millis-bearing ISO `T` form must parse via the ISO fallback")

        // Same instant as the space-separated wire form.
        let wire = PocketBaseDate.date(from: "2026-07-04 08:00:00.000Z")!
        XCTAssertEqual(date!.timeIntervalSince1970, wire.timeIntervalSince1970, accuracy: 0.001,
                       "the ISO form must resolve to the same instant as the wire form")
    }

    // MARK: - searchDecks no-needle returns input unchanged

    /// A whitespace-only query returns the *same* decks in the *same* order
    /// (input is returned unchanged — not re-derived, no reordering).
    func testSearchNoNeedleReturnsInputUnchanged() {
        let decks = [
            Deck(id: "z", owner: "u", name: "Zed"),
            Deck(id: "a", owner: "u", name: "Apple"),
            Deck(id: "m", owner: "u", name: "Mango"),
        ]
        let result = DeckGrouping.searchDecks(decks, query: "   \n ")
        XCTAssertEqual(result.map(\.id), decks.map(\.id),
                       "a no-needle query returns the input order unchanged, no sort applied")
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
