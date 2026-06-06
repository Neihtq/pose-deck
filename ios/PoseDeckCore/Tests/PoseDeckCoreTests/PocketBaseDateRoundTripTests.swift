import XCTest
@testable import PoseDeckCore

/// Round-trip coverage for `PocketBaseDate`: a Date encoded to the wire format
/// and parsed back must recover the same instant, and a Date that survives a
/// full model encode -> JSON -> decode cycle must be unchanged. Also pins the
/// encoder's wire shape (space separator, millis, trailing Z) and the
/// sanitize-empty-datetime behaviour the decode path depends on.
final class PocketBaseDateRoundTripTests: XCTestCase {

    /// Date -> string -> date recovers the same instant (millisecond precision).
    func testDateStringDateRoundTrip() {
        let original = Date(timeIntervalSince1970: 1_700_000_000.172)
        let encoded = PocketBaseDate.string(from: original)
        let reparsed = PocketBaseDate.date(from: encoded)
        XCTAssertNotNil(reparsed)
        XCTAssertEqual(original.timeIntervalSince1970, reparsed!.timeIntervalSince1970, accuracy: 0.001)
    }

    /// The encoder emits the PocketBase wire shape, not ISO `.iso8601`.
    func testEncodedStringUsesPocketBaseWireShape() {
        let date = PocketBaseDate.date(from: "2026-07-04 08:00:00.000Z")!
        let s = PocketBaseDate.string(from: date)
        XCTAssertEqual(s, "2026-07-04 08:00:00.000Z")
        XCTAssertFalse(s.contains("T"), "wire format uses a space separator, not 'T'")
        XCTAssertTrue(s.hasSuffix("Z"))
    }

    /// A full model encode/decode cycle preserves a non-nil Date and the nil-ness
    /// of an unset one. `makeEncoder` writes the wire format; `decode` sanitizes
    /// empty-string datetimes and parses them back.
    func testModelEncodeDecodeRoundTripPreservesDates() throws {
        let shoot = PocketBaseDate.date(from: "2026-07-04 08:00:00.000Z")!
        let updated = PocketBaseDate.date(from: "2026-06-01 12:00:00.123Z")!
        let deck = Deck(
            id: "d1",
            owner: "u",
            name: "Beach",
            shootDate: shoot,
            clientUpdatedAt: updated,
            deletedAt: nil
        )

        let data = try PocketBaseDate.makeEncoder().encode(deck)
        let decoded = try PocketBaseDate.decode(Deck.self, from: data)

        XCTAssertEqual(decoded.id, "d1")
        XCTAssertEqual(decoded.shootDate?.timeIntervalSince1970 ?? -1,
                       shoot.timeIntervalSince1970, accuracy: 0.001,
                       "shoot_date must survive the round trip")
        XCTAssertEqual(decoded.clientUpdatedAt?.timeIntervalSince1970 ?? -1,
                       updated.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertNil(decoded.deletedAt, "an unset Date must remain nil through the round trip")
    }

    /// Round-trips through the wire format are idempotent: re-encoding a parsed
    /// string yields the identical string.
    func testStringRoundTripIsIdempotent() {
        let raw = "2026-12-31 23:59:59.999Z"
        let once = PocketBaseDate.string(from: PocketBaseDate.date(from: raw)!)
        let twice = PocketBaseDate.string(from: PocketBaseDate.date(from: once)!)
        XCTAssertEqual(once, raw)
        XCTAssertEqual(twice, raw, "encoding is stable across repeated round trips")
    }

    /// Sanitization rewrites empty-string values *only* at known datetime keys,
    /// leaving other empty strings (e.g. an empty `notes`) intact.
    func testSanitizeOnlyTouchesDatetimeKeys() throws {
        let json = #"{"id":"c1","deck":"d1","position":1000,"title":"T","notes":"","deleted_at":""}"#
        let card = try PocketBaseDate.decode(Card.self, from: Data(json.utf8))
        XCTAssertEqual(card.notes, "", "non-datetime empty string must be preserved, not nulled")
        XCTAssertNil(card.deletedAt, "empty-string datetime key must decode to nil")
    }

    /// A malformed non-empty datetime surfaces as a decoding error rather than a
    /// silent sentinel date (strict-by-design, per PocketBaseDate docs).
    func testMalformedNonEmptyDatetimeThrows() {
        let json = #"{"id":"d1","owner":"u","name":"X","shoot_date":"not-a-date","deleted_at":""}"#
        XCTAssertThrowsError(try PocketBaseDate.decode(Deck.self, from: Data(json.utf8)),
                             "a malformed datetime must error, not become a sentinel")
    }
}
