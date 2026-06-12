import XCTest
@testable import PoseDeckCore

/// Coverage for the protected-file URL → record-id parse that the image blob
/// cache keys on (the `?token=` query rotates per mint, so the record id is the
/// stable cache key).
final class CardImageFileURLTests: XCTestCase {

    func testExtractsRecordIdFromTokenBearingURL() {
        let url = URL(string: "https://api.example.com/api/files/card_images/abc123/photo.jpg?token=xyz")!
        XCTAssertEqual(CardImageFileURL.recordId(from: url), "abc123")
    }

    func testExtractsRecordIdWithoutToken() {
        let url = URL(string: "http://localhost:8090/api/files/card_images/rec_42/img.jpeg")!
        XCTAssertEqual(CardImageFileURL.recordId(from: url), "rec_42")
    }

    func testTokenRotationDoesNotChangeRecordId() {
        // The whole point: two URLs for the same image with different tokens map
        // to the same cache key.
        let a = URL(string: "http://h/api/files/card_images/same/f.jpg?token=AAA")!
        let b = URL(string: "http://h/api/files/card_images/same/f.jpg?token=BBB")!
        XCTAssertEqual(CardImageFileURL.recordId(from: a), CardImageFileURL.recordId(from: b))
        XCTAssertEqual(CardImageFileURL.recordId(from: a), "same")
    }

    func testNonFilesURLReturnsNil() {
        let url = URL(string: "http://h/api/collections/card_images/records/abc")!
        XCTAssertNil(CardImageFileURL.recordId(from: url), "a non-/api/files/ path is not a file URL")
    }

    func testMissingFilenameReturnsNil() {
        // No filename segment → no concrete file → no blob key.
        let url = URL(string: "http://h/api/files/card_images/abc")!
        XCTAssertNil(CardImageFileURL.recordId(from: url))
    }

    func testThumbVariantFilenameStillKeysByRecordId() {
        // PocketBase thumb URLs append the filename's thumb spec but keep the
        // same record id at the same position.
        let url = URL(string: "http://h/api/files/card_images/rec9/photo.jpg?thumb=100x100&token=t")!
        XCTAssertEqual(CardImageFileURL.recordId(from: url), "rec9")
    }

    func testPercentEncodedFilenameDoesNotBreakParse() {
        let url = URL(string: "http://h/api/files/card_images/rec_x/my%20photo.jpg?token=t")!
        XCTAssertEqual(CardImageFileURL.recordId(from: url), "rec_x")
    }
}
