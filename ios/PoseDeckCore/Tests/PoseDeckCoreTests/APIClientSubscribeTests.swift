import XCTest
@testable import PoseDeckCore

/// Regression coverage for SWIFT-4: the realtime `subscribe(collection:)` stub
/// must throw a catchable `APIClientError.notImplemented` rather than calling
/// `fatalError` (which would abort the process for an M3 integrator who does a
/// normal `try await client.subscribe(...)`).
final class APIClientSubscribeTests: XCTestCase {

    func testSubscribeThrowsNotImplementedInsteadOfCrashing() async {
        let client = APIClient(baseURL: URL(string: "http://localhost:8090")!)

        do {
            try await client.subscribe(collection: "decks")
            XCTFail("subscribe(collection:) should throw until the M3 realtime layer lands")
        } catch let error as APIClientError {
            guard case .notImplemented = error else {
                XCTFail("Expected APIClientError.notImplemented, got \(error)")
                return
            }
            // Reaching here proves the call is recoverable, not a hard crash.
        } catch {
            XCTFail("Expected APIClientError.notImplemented, got \(error)")
        }
    }
}
