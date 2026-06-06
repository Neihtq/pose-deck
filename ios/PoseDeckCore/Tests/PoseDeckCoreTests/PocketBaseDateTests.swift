import XCTest
@testable import PoseDeckCore

/// Tests for PocketBase datetime parsing/encoding and the empty-string-unset
/// sanitization that lets optional `Date?` fields decode to `nil`.
final class PocketBaseDateTests: XCTestCase {

    func testParsesRealPocketBaseDateString() {
        // The exact shape PocketBase emits: space separator, ms, trailing Z.
        let raw = "2026-06-06 18:44:54.172Z"
        let date = PocketBaseDate.date(from: raw)
        XCTAssertNotNil(date, "must parse the PocketBase wire format")

        // 2026-06-06 18:44:54.172 UTC
        var comps = DateComponents()
        comps.year = 2026; comps.month = 6; comps.day = 6
        comps.hour = 18; comps.minute = 44; comps.second = 54
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let expected = cal.date(from: comps)!
        XCTAssertEqual(date!.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 0.5)
    }

    func testEmptyStringDecodesToNil() {
        XCTAssertNil(PocketBaseDate.date(from: ""), "empty string is the unset representation")
    }

    func testRoundTripWireFormat() {
        let raw = "2026-06-06 18:44:54.172Z"
        let date = PocketBaseDate.date(from: raw)!
        let encoded = PocketBaseDate.string(from: date)
        let reparsed = PocketBaseDate.date(from: encoded)!
        XCTAssertEqual(date.timeIntervalSince1970, reparsed.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(encoded, "2026-06-06 18:44:54.172Z", "encode must reproduce the PB wire format")
    }

    func testDecodeDeckWithRealPocketBaseDatesAndEmptyDeletedAt() throws {
        // A realistic PocketBase record body: space-separated dates, deleted_at "".
        let json = """
        {
          "id": "d_1",
          "owner": "u_abc123",
          "name": "Beach shoot",
          "shoot_date": "2026-07-04 08:00:00.000Z",
          "client_updated_at": "2026-06-01 12:00:00.000Z",
          "created": "2026-05-01 12:00:00.000Z",
          "updated": "2026-06-01 12:00:00.123Z",
          "deleted_at": ""
        }
        """
        let deck = try PocketBaseDate.decode(Deck.self, from: Data(json.utf8))
        XCTAssertEqual(deck.id, "d_1")
        XCTAssertNotNil(deck.shootDate, "space-separated PB date must decode")
        XCTAssertNotNil(deck.clientUpdatedAt)
        XCTAssertNotNil(deck.created)
        XCTAssertNotNil(deck.updated)
        XCTAssertNil(deck.deletedAt, "empty-string deleted_at must decode to nil")
    }

    func testDecodeListEnvelopeWithEmptyDatetimes() throws {
        // The empty-string sanitization must reach nested array items too.
        let json = """
        {
          "page": 1, "perPage": 50, "totalItems": 1, "totalPages": 1,
          "items": [
            {
              "id": "c_1", "deck": "d_1", "position": 1000, "title": "Shot",
              "client_updated_at": "2026-06-01 12:00:00.000Z",
              "deleted_at": ""
            }
          ]
        }
        """
        let decoded = try PocketBaseDate.decode(ListResponse<Card>.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.items.count, 1)
        XCTAssertNil(decoded.items[0].deletedAt, "nested empty-string deleted_at must decode to nil")
        XCTAssertNotNil(decoded.items[0].clientUpdatedAt)
    }

    func testParsesFractionlessPocketBaseDateString() {
        // Regression (SPEC-2): a PocketBase datetime with no fractional seconds
        // must still parse to the real instant, not silently become nil/"unset".
        let raw = "2026-06-06 18:44:54Z"
        let date = PocketBaseDate.date(from: raw)
        XCTAssertNotNil(date, "fractionless PB wire format must parse, not return nil")

        var comps = DateComponents()
        comps.year = 2026; comps.month = 6; comps.day = 6
        comps.hour = 18; comps.minute = 44; comps.second = 54
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let expected = cal.date(from: comps)!
        XCTAssertEqual(date!.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 0.5)
    }

    func testParsesFractionlessISODateString() {
        // The `T`-separated ISO form without millis must also parse.
        let raw = "2026-06-06T18:44:54Z"
        let date = PocketBaseDate.date(from: raw)
        XCTAssertNotNil(date, "fractionless ISO form must parse, not return nil")

        var comps = DateComponents()
        comps.year = 2026; comps.month = 6; comps.day = 6
        comps.hour = 18; comps.minute = 44; comps.second = 54
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let expected = cal.date(from: comps)!
        XCTAssertEqual(date!.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 0.5)
    }

    func testDecodeDeckWithFractionlessShootDate() throws {
        // Regression (SPEC-2): a record whose shoot_date lacks millis must decode
        // to a real Date so DeckGrouping classifies it as Upcoming/Past, not
        // Undated.
        let json = """
        {
          "id": "d_2",
          "owner": "u_abc123",
          "name": "Sunset shoot",
          "shoot_date": "2026-07-04 08:00:00Z",
          "created": "2026-05-01 12:00:00Z",
          "updated": "2026-06-01 12:00:00Z",
          "deleted_at": ""
        }
        """
        let deck = try PocketBaseDate.decode(Deck.self, from: Data(json.utf8))
        XCTAssertNotNil(deck.shootDate, "fractionless shoot_date must decode to a real Date")
        XCTAssertNotNil(deck.created)
        XCTAssertNotNil(deck.updated)
        XCTAssertNil(deck.deletedAt)
    }

    func testNonOptionalEmptyDatetimeWouldThrowViaStrategy() {
        // Sanity: the raw strategy (without sanitization) rejects empty strings,
        // which is why sanitization exists. A non-datetime empty string must be
        // left untouched by sanitization.
        let json = #"{"id":"x","name":"","owner":"u","deleted_at":""}"#
        XCTAssertNoThrow(try PocketBaseDate.decode(Deck.self, from: Data(json.utf8)),
                         "empty non-datetime string (name) must not be touched")
    }
}
