import XCTest
@testable import PoseDeckCore

/// Classification coverage for ``MutationSender`` (M3 plan, STEP 8): 2xx →
/// success, 401 → authExpired (distinct), 400-duplicate-id-on-create → success
/// (idempotent lost-ack replay), other 4xx → drop, 429/5xx/offline → retry.
/// Exercised offline via ``StubURLProtocol``.
final class MutationSenderTests: XCTestCase {

    override func tearDown() {
        StubURLProtocol.shared.reset()
        super.tearDown()
    }

    private func makeSender() async -> MutationSender {
        let client = APIClient(
            baseURL: URL(string: "http://stub.local")!,
            session: StubURLProtocol.makeSession()
        )
        await client.setAuthToken("tok")
        return MutationSender(client: client)
    }

    private func createEntry(id: String = "abc123def456ghi") -> OutboxEntry {
        OutboxEntry(
            type: .create,
            entity: "decks",
            payload: Data(#"{"id":"\#(id)","name":"X"}"#.utf8)
        )
    }

    private func updateEntry(id: String = "abc123def456ghi") -> OutboxEntry {
        OutboxEntry(
            type: .update,
            entity: "decks",
            payload: Data(#"{"id":"\#(id)","name":"Y"}"#.utf8)
        )
    }

    // MARK: - Pure classify()

    func testClassify2xxIsSuccess() {
        XCTAssertEqual(MutationSender.classify(status: 200, body: Data(), type: .create), .success)
        XCTAssertEqual(MutationSender.classify(status: 204, body: Data(), type: .delete), .success)
    }

    func testClassify401IsAuthExpired() {
        XCTAssertEqual(MutationSender.classify(status: 401, body: Data(), type: .update), .authExpired)
    }

    func testClassify400DuplicateIdOnCreateIsSuccess() {
        let body = Data(#"{"data":{"id":{"code":"validation_not_unique","message":"Value must be unique."}}}"#.utf8)
        XCTAssertEqual(MutationSender.classify(status: 400, body: body, type: .create), .success)
    }

    func testClassify400DuplicateIdOnUpdateIsNotSuccess() {
        // The idempotent-replay rule applies to creates only.
        let body = Data(#"{"data":{"id":{"code":"x","message":"y"}}}"#.utf8)
        XCTAssertEqual(MutationSender.classify(status: 400, body: body, type: .update), .drop(status: 400))
    }

    func testClassify400NonIdValidationDrops() {
        let body = Data(#"{"data":{"name":{"code":"validation_required","message":"Cannot be blank."}}}"#.utf8)
        XCTAssertEqual(MutationSender.classify(status: 400, body: body, type: .create), .drop(status: 400))
    }

    func testClassifyOther4xxDrops() {
        XCTAssertEqual(MutationSender.classify(status: 403, body: Data(), type: .update), .drop(status: 403))
        XCTAssertEqual(MutationSender.classify(status: 404, body: Data(), type: .delete), .drop(status: 404))
    }

    func testClassify429IsRetry() {
        if case .retry = MutationSender.classify(status: 429, body: Data(), type: .create) {} else {
            XCTFail("429 must be retryable")
        }
    }

    func testClassify5xxIsRetry() {
        if case .retry = MutationSender.classify(status: 503, body: Data(), type: .create) {} else {
            XCTFail("503 must be retryable")
        }
    }

    // MARK: - End-to-end through the stub

    func testCreateSuccessThroughStub() async {
        StubURLProtocol.shared.setHandler { _ in (200, Data(#"{"id":"abc123def456ghi"}"#.utf8)) }
        let outcome = await (await makeSender()).send(createEntry())
        XCTAssertEqual(outcome, .success)
        // POSTs to the create path.
        XCTAssertEqual(StubURLProtocol.shared.requests.first?.httpMethod, "POST")
        XCTAssertEqual(StubURLProtocol.shared.requests.first?.url?.path, "/api/collections/decks/records")
    }

    func testCreateDuplicateIdThroughStubIsSuccess() async {
        StubURLProtocol.shared.setHandler { _ in
            (400, Data(#"{"data":{"id":{"code":"validation_not_unique","message":"x"}}}"#.utf8))
        }
        let outcome = await (await makeSender()).send(createEntry())
        XCTAssertEqual(outcome, .success, "duplicate-id create is the idempotent lost-ack replay")
    }

    func testUpdateRoutesToRecordPathFromPayloadId() async {
        StubURLProtocol.shared.setHandler { _ in (200, Data("{}".utf8)) }
        _ = await (await makeSender()).send(updateEntry(id: "card99"))
        XCTAssertEqual(StubURLProtocol.shared.requests.first?.httpMethod, "PATCH")
        XCTAssertEqual(StubURLProtocol.shared.requests.first?.url?.path, "/api/collections/decks/records/card99")
    }

    func testUnauthorizedThroughStubIsAuthExpired() async {
        StubURLProtocol.shared.setHandler { _ in (401, Data("{}".utf8)) }
        let outcome = await (await makeSender()).send(updateEntry())
        XCTAssertEqual(outcome, .authExpired)
    }

    func testServerErrorThroughStubIsRetry() async {
        StubURLProtocol.shared.setHandler { _ in (503, Data("{}".utf8)) }
        let outcome = await (await makeSender()).send(updateEntry())
        if case .retry = outcome {} else { XCTFail("503 must be retry, got \(outcome)") }
    }

    func testIdempotencyHeaderIsSent() async {
        StubURLProtocol.shared.setHandler { _ in (200, Data("{}".utf8)) }
        let entry = createEntry()
        _ = await (await makeSender()).send(entry)
        let header = StubURLProtocol.shared.requests.first?.value(forHTTPHeaderField: "X-Idempotency-Key")
        XCTAssertEqual(header, entry.idempotencyKey.uuidString)
    }
}
