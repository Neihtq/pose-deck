import XCTest
@testable import PoseDeckCore

/// Regression for SEC-3: PocketBase filter values must be escaped so a value
/// containing a double-quote can never break out of the quoted literal and
/// inject extra clauses. Covers both the pure escaping helper and the
/// repository call sites that route ids through it.
final class PocketBaseFilterTests: XCTestCase {

    override func tearDown() {
        StubURLProtocol.shared.reset()
        super.tearDown()
    }

    // MARK: - Pure escaping helper

    func testPlainAlphanumericIsUnchanged() {
        XCTAssertEqual(PocketBaseFilter.escape("abc123XYZ"), "abc123XYZ")
        XCTAssertEqual(PocketBaseFilter.quoted("abc123XYZ"), "\"abc123XYZ\"")
    }

    func testDoubleQuoteIsEscaped() {
        // The classic injection: close the literal, OR in a widening clause.
        let malicious = #"x" || id != "y"#
        let quoted = PocketBaseFilter.quoted(malicious)
        // The only structural (unescaped) quotes are the opening/closing pair.
        XCTAssertTrue(quoted.hasPrefix("\""))
        XCTAssertTrue(quoted.hasSuffix("\""))
        // Every interior double-quote must be backslash-escaped.
        XCTAssertFalse(quoted.contains(#"" || id != ""#),
                       "injected quote must not appear unescaped")
        XCTAssertTrue(quoted.contains(#"\""#), "interior quotes must be escaped")
    }

    func testBackslashIsEscapedBeforeQuote() {
        // A trailing backslash must not escape the closing quote of the literal.
        let value = #"abc\"#
        XCTAssertEqual(PocketBaseFilter.escape(value), #"abc\\"#)
        XCTAssertEqual(PocketBaseFilter.quoted(value), #""abc\\""#)
    }

    func testBackslashQuotePairIsFullyEscaped() {
        // `\"` should become `\\\"` — backslash escaped, then quote escaped —
        // so neither character can terminate the literal.
        XCTAssertEqual(PocketBaseFilter.escape(#"\""#), #"\\\""#)
    }

    func testControlCharactersAreStripped() {
        let value = "a\nb\tc\u{0}d"
        XCTAssertEqual(PocketBaseFilter.escape(value), "abcd",
                       "control characters must be dropped from filter literals")
    }

    // MARK: - Repository call sites emit escaped filters

    /// `getDeck` must send an escaped filter so a quote in the id cannot break
    /// out of the quoted literal in the `filter` query parameter.
    func testGetDeckEscapesIdInFilter() async throws {
        StubURLProtocol.shared.setHandler { _ in
            (200, Data(#"{"page":1,"perPage":1,"totalItems":0,"totalPages":0,"items":[]}"#.utf8))
        }
        let client = APIClient(baseURL: URL(string: "http://stub.local")!,
                               session: StubURLProtocol.makeSession())
        await client.setAuthToken("test-token")
        let repo = DeckRepository(client: client)

        let malicious = #"x" || id != "y"#
        _ = try? await repo.getDeck(id: malicious)

        let url = StubURLProtocol.shared.requests.first?.url?.absoluteString ?? ""
        let decoded = url.removingPercentEncoding ?? url
        // The malicious raw fragment must NOT appear; its quotes are escaped.
        XCTAssertFalse(decoded.contains(#"id = "x" || id != "y""#),
                       "raw unescaped injection must not reach the filter")
        XCTAssertTrue(decoded.contains(#"id = "x\" || id != \"y""#),
                      "the id must be embedded as an escaped quoted literal")
    }
}
