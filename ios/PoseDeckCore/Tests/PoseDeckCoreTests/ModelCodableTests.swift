import XCTest
@testable import PoseDeckCore

/// JSON round-trip tests for every model against sample PocketBase-shaped JSON.
/// These verify snake_case `CodingKeys` mapping, enum decoding, and optional fields.
final class ModelCodableTests: XCTestCase {

    private func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// Decode JSON, re-encode, decode again, and assert the two decoded values match.
    private func assertRoundTrip<T: Codable & Equatable>(_ type: T.Type, json: String) throws -> T {
        let decoder = makeDecoder()
        let encoder = makeEncoder()
        let original = try decoder.decode(T.self, from: Data(json.utf8))
        let reencoded = try encoder.encode(original)
        let roundTripped = try decoder.decode(T.self, from: reencoded)
        XCTAssertEqual(original, roundTripped, "Round-trip mismatch for \(T.self)")
        return original
    }

    func testUserDecodesAndRoundTrips() throws {
        let json = """
        {
          "id": "u_abc123",
          "email": "owner@example.com",
          "name": "Owner",
          "created": "2026-01-01T10:00:00.000Z",
          "updated": "2026-02-01T10:00:00.000Z"
        }
        """
        let user = try assertRoundTrip(User.self, json: json)
        XCTAssertEqual(user.id, "u_abc123")
        XCTAssertEqual(user.email, "owner@example.com")
        XCTAssertEqual(user.name, "Owner")
        XCTAssertNotNil(user.created)
        XCTAssertNotNil(user.updated)
    }

    func testDeckMapsSnakeCaseAndOptionalFields() throws {
        let json = """
        {
          "id": "d_1",
          "owner": "u_abc123",
          "name": "Beach shoot",
          "shoot_date": "2026-07-04T08:00:00.000Z",
          "client_updated_at": "2026-06-01T12:00:00.000Z",
          "created": "2026-05-01T12:00:00.000Z",
          "updated": "2026-06-01T12:00:00.000Z",
          "deleted_at": null
        }
        """
        let deck = try assertRoundTrip(Deck.self, json: json)
        XCTAssertEqual(deck.id, "d_1")
        XCTAssertEqual(deck.owner, "u_abc123")
        XCTAssertEqual(deck.name, "Beach shoot")
        XCTAssertNotNil(deck.shootDate, "shoot_date should map to shootDate")
        XCTAssertNotNil(deck.clientUpdatedAt, "client_updated_at should map to clientUpdatedAt")
        XCTAssertNil(deck.deletedAt, "deleted_at null should decode to nil")
    }

    func testDeckOmittedOptionalFields() throws {
        // PocketBase may omit optional fields entirely; ensure decoding still works.
        let json = """
        {
          "id": "d_2",
          "owner": "u_abc123",
          "name": "Undated deck"
        }
        """
        let deck = try assertRoundTrip(Deck.self, json: json)
        XCTAssertNil(deck.shootDate)
        XCTAssertNil(deck.clientUpdatedAt)
        XCTAssertNil(deck.created)
        XCTAssertNil(deck.deletedAt)
    }

    func testCardMapsTimeSlotAndAllOptionals() throws {
        let json = """
        {
          "id": "c_1",
          "deck": "d_1",
          "position": 1000,
          "title": "Golden hour portrait",
          "time_slot": "18:30",
          "subjects": "Anna, Ben",
          "direction": "Look left, soft smile",
          "notes": "Bring reflector.\\nWatch the horizon line.",
          "client_updated_at": "2026-06-01T12:00:00.000Z",
          "created": "2026-05-01T12:00:00.000Z",
          "updated": "2026-06-01T12:00:00.000Z",
          "deleted_at": null
        }
        """
        let card = try assertRoundTrip(Card.self, json: json)
        XCTAssertEqual(card.deck, "d_1")
        XCTAssertEqual(card.position, 1000)
        XCTAssertEqual(card.title, "Golden hour portrait")
        XCTAssertEqual(card.timeSlot, "18:30", "time_slot should map to timeSlot")
        XCTAssertEqual(card.subjects, "Anna, Ben")
        XCTAssertEqual(card.direction, "Look left, soft smile")
        XCTAssertTrue(card.notes?.contains("reflector") ?? false)
        XCTAssertNil(card.deletedAt)
    }

    func testCardImageDecodesFileField() throws {
        let json = """
        {
          "id": "ci_1",
          "card": "c_1",
          "position": 0,
          "file": "ref_a1b2c3.jpg",
          "created": "2026-05-01T12:00:00.000Z"
        }
        """
        let image = try assertRoundTrip(CardImage.self, json: json)
        XCTAssertEqual(image.card, "c_1")
        XCTAssertEqual(image.position, 0)
        XCTAssertEqual(image.file, "ref_a1b2c3.jpg")
    }

    func testDeckGuestMapsGrantedAt() throws {
        let json = """
        {
          "id": "dg_1",
          "deck": "d_1",
          "user": "u_friend",
          "granted_at": "2026-06-02T09:00:00.000Z"
        }
        """
        let guest = try assertRoundTrip(DeckGuest.self, json: json)
        XCTAssertEqual(guest.deck, "d_1")
        XCTAssertEqual(guest.user, "u_friend")
        XCTAssertNotNil(guest.grantedAt, "granted_at should map to grantedAt")
    }

    func testCardCompletionDecodesEnumStates() throws {
        let cases: [(String, CardCompletion.State)] = [
            ("done", .done),
            ("skipped", .skipped),
            ("pending", .pending),
        ]
        for (raw, expected) in cases {
            let json = """
            {
              "id": "cc_\(raw)",
              "card": "c_1",
              "user": "u_abc123",
              "state": "\(raw)",
              "changed_at": "2026-06-03T15:30:00.000Z"
            }
            """
            let completion = try assertRoundTrip(CardCompletion.self, json: json)
            XCTAssertEqual(completion.state, expected, "state '\(raw)' should decode to \(expected)")
            XCTAssertNotNil(completion.changedAt, "changed_at should map to changedAt")
        }
    }

    func testCardCompletionRejectsUnknownState() throws {
        let json = """
        {
          "id": "cc_x",
          "card": "c_1",
          "user": "u_abc123",
          "state": "bogus",
          "changed_at": "2026-06-03T15:30:00.000Z"
        }
        """
        let decoder = makeDecoder()
        XCTAssertThrowsError(try decoder.decode(CardCompletion.self, from: Data(json.utf8))) { error in
            XCTAssertTrue(error is DecodingError, "Unknown enum value should throw a DecodingError")
        }
    }

    func testEncodedDeckUsesSnakeCaseKeys() throws {
        let deck = Deck(
            id: "d_3",
            owner: "u_abc123",
            name: "Encoding check",
            shootDate: Date(timeIntervalSince1970: 1_700_000_000),
            clientUpdatedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let data = try makeEncoder().encode(deck)
        let string = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(string.contains("\"shoot_date\""), "Encoded JSON should use snake_case shoot_date")
        XCTAssertTrue(string.contains("\"client_updated_at\""), "Encoded JSON should use snake_case client_updated_at")
        XCTAssertFalse(string.contains("\"shootDate\""), "Encoded JSON must not use camelCase keys")
    }
}
