import XCTest
@testable import PoseDeckCore

/// Offline tests for the image-cap rule, multipart encoding, and the
/// upload/token/url flow exercised via `StubURLProtocol`.
final class ImageRepositoryTests: XCTestCase {

    override func tearDown() {
        StubURLProtocol.shared.reset()
        super.tearDown()
    }

    private func makeClient() async -> APIClient {
        let client = APIClient(
            baseURL: URL(string: "http://stub.local")!,
            session: StubURLProtocol.makeSession()
        )
        await client.setAuthToken("test-token")
        return client
    }

    func testCapAllowsAddWhenUnderLimit() {
        XCTAssertNoThrow(
            try ImageRepository.checkCanAddImage(existingCount: 0, max: 5, cardId: "c_1")
        )
        XCTAssertNoThrow(
            try ImageRepository.checkCanAddImage(existingCount: 4, max: 5, cardId: "c_1")
        )
    }

    func testCapThrowsAtLimit() {
        XCTAssertThrowsError(
            try ImageRepository.checkCanAddImage(existingCount: 5, max: 5, cardId: "c_1")
        ) { error in
            XCTAssertEqual(error as? ImageRepositoryError, .tooManyImages(cardId: "c_1"))
        }
    }

    func testCapThrowsAboveLimit() {
        XCTAssertThrowsError(
            try ImageRepository.checkCanAddImage(existingCount: 6, max: 5, cardId: "c_2")
        ) { error in
            XCTAssertEqual(error as? ImageRepositoryError, .tooManyImages(cardId: "c_2"))
        }
    }

    // MARK: - Synchronous upload gate (SWIFT-3 regression)

    func testUploadGateAllowsWhenIdleAndUnderLimit() {
        XCTAssertEqual(
            ImageUploadGate.evaluate(isUploading: false, atImageLimit: false),
            .allowed
        )
    }

    func testUploadGateBlocksWhenAtLimit() {
        XCTAssertEqual(
            ImageUploadGate.evaluate(isUploading: false, atImageLimit: true),
            .atLimit
        )
    }

    /// Regression for SWIFT-3: the in-flight guard must win even when the
    /// count-based `atImageLimit` is still stale (false), so a second upload
    /// dispatched while the first is suspended is rejected before it can append
    /// and transiently exceed the cap. Mirrors the web `inFlight` ref.
    func testUploadGateBlocksConcurrentUploadWhileFirstInFlight() {
        // First upload is in flight; its append has not landed yet so the
        // count-based limit check still reads "not at limit".
        XCTAssertEqual(
            ImageUploadGate.evaluate(isUploading: true, atImageLimit: false),
            .busy,
            "a second upload must be rejected while the first is in flight, "
                + "even though the stale count check says there is room"
        )
    }

    func testUploadGateInFlightGuardTakesPriorityOverLimit() {
        // When both conditions hold, the in-flight guard is reported first:
        // it is the guard that actually closes the check-then-act race.
        XCTAssertEqual(
            ImageUploadGate.evaluate(isUploading: true, atImageLimit: true),
            .busy
        )
    }

    func testDefaultMaxIsFive() {
        // Build with a dummy client; we only read the configured cap.
        let client = APIClient(baseURL: URL(string: "http://127.0.0.1:8090")!)
        let repo = ImageRepository(client: client)
        XCTAssertEqual(repo.maxImagesPerCard, 5)
    }

    func testMultipartEncodingIncludesFieldsAndFile() {
        let fields: [APIClient.MultipartField] = [
            .text(name: "card", value: "c_1"),
            .text(name: "position", value: "1000"),
            .file(name: "file", filename: "image.jpg", mimeType: "image/jpeg", data: Data([0xFF, 0xD8, 0xFF])),
        ]
        let body = APIClient.encodeMultipart(fields: fields, boundary: "BOUND")
        let text = String(decoding: body, as: UTF8.self)

        XCTAssertTrue(text.contains("--BOUND\r\n"), "uses the boundary")
        XCTAssertTrue(text.contains("name=\"card\""))
        XCTAssertTrue(text.contains("c_1"))
        XCTAssertTrue(text.contains("name=\"position\""))
        XCTAssertTrue(text.contains("filename=\"image.jpg\""))
        XCTAssertTrue(text.contains("Content-Type: image/jpeg"))
        XCTAssertTrue(text.contains("--BOUND--\r\n"), "closing boundary")
    }

    // MARK: - SEC-3: multipart header parameter escaping

    /// Regression for SEC-3: a CRLF or double-quote in a field `name`/`filename`
    /// must not be able to close the quoted Content-Disposition parameter or
    /// inject extra part headers / break the multipart boundary. Mirrors the
    /// defense-in-depth norm already applied to PocketBase filter interpolation.
    func testMultipartEscapesQuotesAndCRLFInNameAndFilename() {
        // A hostile filename: a closing quote + CRLF that would otherwise inject
        // a forged Content-Type header into the part, plus a stray boundary.
        let evilFilename = "a\"\r\nContent-Type: text/html\r\n\r\n--BOUND--\r\n.jpg"
        let evilName = "fi\"eld\r\nX-Injected: 1"
        let fields: [APIClient.MultipartField] = [
            .file(name: evilName, filename: evilFilename, mimeType: "image/jpeg", data: Data([0xFF])),
        ]
        let body = APIClient.encodeMultipart(fields: fields, boundary: "BOUND")
        let text = String(decoding: body, as: UTF8.self)

        // The injected header text must not have escaped onto its own line: it is
        // defanged only if no CRLF precedes it (it stays inside the quoted param).
        XCTAssertFalse(text.contains("\r\nX-Injected:"),
                       "field name CRLF must not inject a new header line")
        XCTAssertFalse(text.contains("\r\nContent-Type: text/html"),
                       "filename CRLF must not inject a forged Content-Type header")
        // No raw (unescaped) interior double-quote may appear: every quote in the
        // value must be backslash-escaped so it can't close the parameter.
        XCTAssertFalse(text.contains("name=\"fi\"eld"),
                       "interior quote in name must be escaped")
        XCTAssertTrue(text.contains("name=\"fi\\\"eld"),
                      "name's interior quote is backslash-escaped")
        XCTAssertTrue(text.contains("filename=\"a\\\""),
                      "filename's interior quote is backslash-escaped")
        // The exactly one closing boundary is the real one this encoder appends.
        let occurrences = text.components(separatedBy: "--BOUND--\r\n").count - 1
        XCTAssertEqual(occurrences, 1,
                       "a boundary token smuggled via the filename must not produce a second closing boundary line")
    }

    /// The escaping helper is a no-op for the constant values production passes
    /// today, so the hardening does not change real upload payloads.
    func testHeaderParameterEscapeLeavesPlainValuesUnchanged() {
        XCTAssertEqual(APIClient.escapeHeaderParameter("file"), "file")
        XCTAssertEqual(APIClient.escapeHeaderParameter("image.jpg"), "image.jpg")
        XCTAssertEqual(APIClient.escapeHeaderParameter("card"), "card")
    }

    func testFileURLBuilderEmbedsToken() {
        let client = APIClient(baseURL: URL(string: "http://127.0.0.1:8090")!)
        let url = client.fileURL(
            collection: "card_images",
            recordId: "ci_1",
            filename: "photo.jpg",
            token: "tok123"
        )
        XCTAssertEqual(
            url?.absoluteString,
            "http://127.0.0.1:8090/api/files/card_images/ci_1/photo.jpg?token=tok123"
        )
    }

    func testFileURLBuilderOmitsTokenWhenNil() {
        let client = APIClient(baseURL: URL(string: "http://127.0.0.1:8090")!)
        let url = client.fileURL(collection: "card_images", recordId: "ci_1", filename: "photo.jpg")
        XCTAssertEqual(
            url?.absoluteString,
            "http://127.0.0.1:8090/api/files/card_images/ci_1/photo.jpg"
        )
    }

    // MARK: - Flow against the stub

    func testUploadPostsMultipartToCardImages() async throws {
        StubURLProtocol.shared.setHandler { request in
            if request.httpMethod == "GET" {
                // Existing-image count: empty, so the upload is allowed.
                return (200, Data(#"{"page":1,"perPage":5,"totalItems":0,"totalPages":0,"items":[]}"#.utf8))
            }
            return (200, Data(#"{"id":"ci_new","card":"c_1","position":1000,"file":"img.jpg"}"#.utf8))
        }

        let repo = ImageRepository(client: await makeClient())
        let created = try await repo.uploadCardImage(
            cardId: "c_1",
            data: Data([0xFF, 0xD8, 0xFF]),
            position: 1000
        )
        XCTAssertEqual(created.id, "ci_new")
        XCTAssertEqual(created.file, "img.jpg")

        let postRequests = StubURLProtocol.shared.requests.filter { $0.httpMethod == "POST" }
        let post = try XCTUnwrap(postRequests.last)
        XCTAssertTrue(post.url?.path.hasSuffix("/api/collections/card_images/records") ?? false)
        let contentType = post.value(forHTTPHeaderField: "Content-Type") ?? ""
        XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="), "multipart upload")
    }

    func testUploadThrowsWhenCardFull() async {
        StubURLProtocol.shared.setHandler { request in
            // Five existing images -> cap reached.
            let items = (0..<5).map { #"{"id":"ci\#($0)","card":"c_1","position":\#($0)}"# }
                .joined(separator: ",")
            return (200, Data("{\"page\":1,\"perPage\":5,\"totalItems\":5,\"totalPages\":1,\"items\":[\(items)]}".utf8))
        }
        let repo = ImageRepository(client: await makeClient())
        do {
            _ = try await repo.uploadCardImage(cardId: "c_1", data: Data([0x1]), position: 6000)
            XCTFail("Expected tooManyImages")
        } catch {
            XCTAssertEqual(error as? ImageRepositoryError, .tooManyImages(cardId: "c_1"))
        }
        // No POST should have been attempted once the cap is hit.
        XCTAssertTrue(StubURLProtocol.shared.requests.allSatisfy { $0.httpMethod != "POST" })
    }

    func testListSortsByPosition() async throws {
        StubURLProtocol.shared.setHandler { _ in
            let body = #"""
            {"page":1,"perPage":5,"totalItems":2,"totalPages":1,"items":[
              {"id":"b","card":"c_1","position":2000,"file":"b.jpg"},
              {"id":"a","card":"c_1","position":1000,"file":"a.jpg"}
            ]}
            """#
            return (200, Data(body.utf8))
        }
        let repo = ImageRepository(client: await makeClient())
        let images = try await repo.listCardImages(cardId: "c_1")
        XCTAssertEqual(images.map(\.id), ["a", "b"], "sorted by position ascending")
    }

    /// Regression for `spec-image-list-truncates-page1-ios`: a card holding more
    /// server-side image records than the per-card cap (e.g. an out-of-band
    /// create, a pre-cap migration, or a transient race) must NOT be silently
    /// truncated. The old implementation requested a single page with
    /// `perPage = maxImagesPerCard` (== 5), capping the query at 5 records; the
    /// web reference uses `getFullList`. `listCardImages` now walks all pages via
    /// `client.listAll`, so it returns the complete set regardless of count.
    func testListFetchesAllPagesAndDoesNotTruncate() async throws {
        // Server holds 7 image records for this card (more than the cap of 5),
        // served two-per-page across 4 pages.
        StubURLProtocol.shared.setHandler { request in
            let page = Int(
                URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                    .queryItems?
                    .first(where: { $0.name == "page" })?
                    .value ?? "1"
            ) ?? 1
            // 7 records id'd by descending position so we can also confirm the
            // final ascending sort holds across the page boundaries.
            let all = (0..<7).map { (id: "ci\($0)", position: (7 - $0) * 1000) }
            let perPage = 2
            let start = (page - 1) * perPage
            let slice = all[min(start, all.count)..<min(start + perPage, all.count)]
            let items = slice.map {
                #"{"id":"\#($0.id)","card":"c_1","position":\#($0.position),"file":"\#($0.id).jpg"}"#
            }.joined(separator: ",")
            let body = "{\"page\":\(page),\"perPage\":\(perPage),"
                + "\"totalItems\":7,\"totalPages\":4,\"items\":[\(items)]}"
            return (200, Data(body.utf8))
        }

        let repo = ImageRepository(client: await makeClient())
        let images = try await repo.listCardImages(cardId: "c_1")

        XCTAssertEqual(images.count, 7, "all 7 records must be returned, not truncated to the cap of 5")
        // Sorted ascending by position across all pages.
        XCTAssertEqual(images.map(\.position), [1000, 2000, 3000, 4000, 5000, 6000, 7000])
        // More than one page was actually fetched (proves we did not stop at page 1).
        let getPages = StubURLProtocol.shared.requests
            .filter { $0.httpMethod == "GET" }
            .count
        XCTAssertGreaterThan(getPages, 1, "should walk multiple pages, not just page 1")
    }

    func testFileURLForImageMintsTokenAndBuildsURL() async throws {
        StubURLProtocol.shared.setHandler { request in
            // POST /api/files/token mints the short-lived token.
            (200, Data(#"{"token":"minted-tok"}"#.utf8))
        }
        let repo = ImageRepository(client: await makeClient())
        let image = CardImage(id: "ci_1", card: "c_1", position: 0, file: "photo.jpg")
        let url = try await repo.fileURL(for: image)
        XCTAssertEqual(
            url.absoluteString,
            "http://stub.local/api/files/card_images/ci_1/photo.jpg?token=minted-tok"
        )
    }

    func testFileURLThrowsWhenNoFile() async {
        let repo = ImageRepository(client: await makeClient())
        let image = CardImage(id: "ci_1", card: "c_1", position: 0, file: nil)
        do {
            _ = try await repo.fileURL(for: image)
            XCTFail("Expected invalidFileURL")
        } catch {
            XCTAssertEqual(error as? ImageRepositoryError, .invalidFileURL)
        }
    }
}
