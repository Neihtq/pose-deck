import XCTest
@testable import PoseDeckCore

/// Closes the remaining iOS-milestone gaps in repository CRUD payloads, the
/// duplicate field-copy contract, the PocketBaseDate parse boundaries, and
/// DeckGrouping ordering that the existing suites leave untested:
///
///  - `createCard` defaults *every* unset optional field (time_slot, subjects,
///    direction, notes) to "" in the POST body, and carries the `deck` relation
///    — previously only position / deleted_at / client_updated_at were asserted.
///  - The deck mutations that only ever PATCH (softDelete, restore, setShootDate)
///    target `/api/collections/decks/records/{id}` — only `renameDeck`'s path was
///    pinned before, leaving these three unverified against a path-typo regression.
///  - `duplicateDeck` copies *all* editable card fields (time_slot, subjects,
///    direction) from the source, not just the title/notes the existing test
///    happened to set.
///  - `PocketBaseDate.date(from:)` returns nil (not a sentinel) for a non-empty
///    garbage string — the `nil`-returning branch distinct from the
///    decode-throws path.
///  - `DeckGrouping.searchDecks` preserves the input's relative order in the
///    filtered subset (a filter, not a re-sort).
///
/// All offline via `StubURLProtocol` or pure helpers.
final class RepositoryPayloadGapTests: XCTestCase {

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

    // MARK: - createCard defaults all unset optionals to "" and carries deck

    /// A `createCard` with only a title must send `deck` and *empty strings* for
    /// every unset optional field — matching PocketBase's empty-string
    /// representation so the server never sees a missing key (web `cardApi.ts`
    /// parity). The existing create test asserted position/deleted_at/stamp but
    /// not the four optional text fields.
    func testCreateCardDefaultsAllUnsetOptionalFieldsToEmptyStringAndCarriesDeck() async throws {
        StubURLProtocol.shared.setHandler { request in
            if request.httpMethod == "GET" {
                return (200, Data(#"{"page":1,"perPage":200,"totalItems":0,"totalPages":0,"items":[]}"#.utf8))
            }
            return (200, Data(#"{"id":"c","deck":"d1","position":1000,"title":"x","deleted_at":""}"#.utf8))
        }
        _ = try await (await cardRepo()).createCard(deckId: "d1", fields: .init(title: "Only title"))

        let body = try lastBody()
        XCTAssertEqual(body["deck"] as? String, "d1", "create must carry the deck relation")
        XCTAssertEqual(body["title"] as? String, "Only title")
        XCTAssertEqual(body["time_slot"] as? String, "", "unset time_slot defaults to empty string")
        XCTAssertEqual(body["subjects"] as? String, "", "unset subjects defaults to empty string")
        XCTAssertEqual(body["direction"] as? String, "", "unset direction defaults to empty string")
        XCTAssertEqual(body["notes"] as? String, "", "unset notes defaults to empty string")
        XCTAssertEqual(body["deleted_at"] as? String, "", "new card is live (deleted_at empty)")
        XCTAssertEqual(body["client_updated_at"] as? String, stamp)
    }

    /// Provided optional fields are written verbatim (the "" default is a
    /// default, not a clobber).
    func testCreateCardWritesProvidedOptionalFields() async throws {
        StubURLProtocol.shared.setHandler { request in
            if request.httpMethod == "GET" {
                return (200, Data(#"{"page":1,"perPage":200,"totalItems":0,"totalPages":0,"items":[]}"#.utf8))
            }
            return (200, Data(#"{"id":"c","deck":"d1","position":1000,"title":"x","deleted_at":""}"#.utf8))
        }
        _ = try await (await cardRepo()).createCard(
            deckId: "d1",
            fields: .init(title: "T", timeSlot: "Golden hour", subjects: "Bride", direction: "Look left", notes: "n")
        )
        let body = try lastBody()
        XCTAssertEqual(body["time_slot"] as? String, "Golden hour")
        XCTAssertEqual(body["subjects"] as? String, "Bride")
        XCTAssertEqual(body["direction"] as? String, "Look left")
        XCTAssertEqual(body["notes"] as? String, "n")
    }

    // MARK: - PATCH-only deck mutations target the right collection path

    /// `softDeleteDeck` must PATCH `/api/collections/decks/records/{id}` — a path
    /// typo (wrong collection, or hitting the cards collection) would silently
    /// mutate the wrong record. Only rename's path was pinned before.
    func testSoftDeleteDeckPatchesDeckByIdInDecksCollection() async throws {
        StubURLProtocol.shared.setHandler { _ in
            (200, Data(#"{"id":"d7","owner":"u","name":"X","deleted_at":"2023-11-14 22:13:20.000Z"}"#.utf8))
        }
        _ = try await (await deckRepo()).softDeleteDeck(id: "d7")
        let patches = requests(method: "PATCH")
        XCTAssertEqual(patches.count, 1)
        XCTAssertEqual(patches.first?.url?.path, "/api/collections/decks/records/d7")
        // And it sets deleted_at to the stamp (soft-delete contract).
        XCTAssertEqual(try lastBody()["deleted_at"] as? String, stamp)
    }

    func testRestoreDeckPatchesDeckByIdInDecksCollection() async throws {
        StubURLProtocol.shared.setHandler { _ in
            (200, Data(#"{"id":"d8","owner":"u","name":"X","deleted_at":""}"#.utf8))
        }
        _ = try await (await deckRepo()).restoreDeck(id: "d8")
        XCTAssertEqual(requests(method: "PATCH").first?.url?.path, "/api/collections/decks/records/d8")
        XCTAssertEqual(try lastBody()["deleted_at"] as? String, "", "restore clears deleted_at")
    }

    func testSetShootDatePatchesDeckByIdInDecksCollection() async throws {
        StubURLProtocol.shared.setHandler { _ in
            (200, Data(#"{"id":"d9","owner":"u","name":"X","deleted_at":""}"#.utf8))
        }
        let shoot = PocketBaseDate.date(from: "2026-07-04 08:00:00.000Z")!
        _ = try await (await deckRepo()).setShootDate(id: "d9", shootDate: shoot)
        XCTAssertEqual(requests(method: "PATCH").first?.url?.path, "/api/collections/decks/records/d9")
        XCTAssertEqual(try lastBody()["shoot_date"] as? String, "2026-07-04 08:00:00.000Z")
    }

    // MARK: - duplicateDeck copies all editable card fields

    /// `duplicateDeck` must carry *every* editable field (time_slot, subjects,
    /// direction, notes) from each source card into its copy — the existing
    /// duplicate test only set title/notes, so a dropped time_slot/subjects/
    /// direction in `DuplicateCardBody` would go unnoticed.
    func testDuplicateDeckCopiesAllEditableCardFields() async throws {
        StubURLProtocol.shared.setHandler { request in
            if request.httpMethod == "GET" {
                let url = request.url!.absoluteString
                if url.contains("collections/decks") {
                    return (200, Data(#"{"page":1,"perPage":1,"totalItems":1,"totalPages":1,"items":[{"id":"src","owner":"u","name":"S","shoot_date":"","deleted_at":""}]}"#.utf8))
                }
                let body = #"""
                {"page":1,"perPage":200,"totalItems":1,"totalPages":1,"items":[
                  {"id":"c1","deck":"src","position":1000,"title":"First look","time_slot":"Golden hour","subjects":"Bride & groom","direction":"Look toward the sun","notes":"bring reflector","deleted_at":""}
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

        let copyBody = try XCTUnwrap(
            allBodies().first { $0["deck"] as? String == "copy" },
            "the source card must be copied into the new deck"
        )
        XCTAssertEqual(copyBody["title"] as? String, "First look")
        XCTAssertEqual(copyBody["time_slot"] as? String, "Golden hour", "time_slot must be carried into the copy")
        XCTAssertEqual(copyBody["subjects"] as? String, "Bride & groom", "subjects must be carried into the copy")
        XCTAssertEqual(copyBody["direction"] as? String, "Look toward the sun", "direction must be carried into the copy")
        XCTAssertEqual(copyBody["notes"] as? String, "bring reflector", "notes must be carried into the copy")
    }

    // MARK: - PocketBaseDate garbage returns nil (not throw, not sentinel)

    /// `date(from:)` returns nil for a non-empty garbage string after every
    /// formatter fails — the throws-free contract callers rely on (distinct from
    /// the `decode` path, which surfaces malformed values as a decoding error).
    func testGarbageDateStringReturnsNil() {
        XCTAssertNil(PocketBaseDate.date(from: "not-a-date"))
        XCTAssertNil(PocketBaseDate.date(from: "2026-13-99 99:99:99Z"), "out-of-range components must not parse")
        XCTAssertNil(PocketBaseDate.date(from: "   "), "a whitespace-only string is not a valid datetime")
    }

    // MARK: - DeckGrouping search preserves input order in the filtered subset

    /// `searchDecks` is a filter, not a re-sort: matching decks come back in the
    /// same relative order they appeared in the input.
    func testSearchPreservesInputOrderAmongMatches() {
        let decks = [
            Deck(id: "z", owner: "u", name: "Beach sunset"),
            Deck(id: "a", owner: "u", name: "Studio"),
            Deck(id: "m", owner: "u", name: "Beachfront"),
        ]
        let result = DeckGrouping.searchDecks(decks, query: "beach")
        XCTAssertEqual(result.map(\.id), ["z", "m"],
                       "matches keep their input-relative order; the non-match is dropped")
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

    private func allBodies() -> [[String: Any]] {
        let bodies = StubURLProtocol.shared.bodies
        let reqs = StubURLProtocol.shared.requests
        var out: [[String: Any]] = []
        for i in bodies.indices {
            let m = reqs[i].httpMethod
            if (m == "POST" || m == "PATCH"), !bodies[i].isEmpty,
               let obj = try? JSONSerialization.jsonObject(with: bodies[i]) as? [String: Any] {
                out.append(obj)
            }
        }
        return out
    }
}
