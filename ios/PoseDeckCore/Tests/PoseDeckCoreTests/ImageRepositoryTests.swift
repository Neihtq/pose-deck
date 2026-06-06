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
