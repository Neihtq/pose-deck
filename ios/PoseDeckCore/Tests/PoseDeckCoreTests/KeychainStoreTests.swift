import XCTest
@testable import PoseDeckCore

/// Round-trip behaviour of the keychain abstraction via the in-memory fake.
final class KeychainStoreTests: XCTestCase {

    func testSaveReadRoundTrip() throws {
        let store = InMemoryKeychainStore()
        let payload = Data("jwt-token-bytes".utf8)

        try store.save(payload, for: "token")
        XCTAssertEqual(try store.read("token"), payload)
    }

    func testReadMissingKeyReturnsNil() throws {
        let store = InMemoryKeychainStore()
        XCTAssertNil(try store.read("absent"))
    }

    func testSaveOverwritesExistingValue() throws {
        let store = InMemoryKeychainStore()
        try store.save(Data("old".utf8), for: "k")
        try store.save(Data("new".utf8), for: "k")
        XCTAssertEqual(try store.read("k"), Data("new".utf8))
    }

    func testDeleteRemovesValueAndIsIdempotent() throws {
        let store = InMemoryKeychainStore()
        try store.save(Data("v".utf8), for: "k")
        try store.delete("k")
        XCTAssertNil(try store.read("k"))
        // Deleting again must not throw.
        XCTAssertNoThrow(try store.delete("k"))
    }

    func testStringConvenienceRoundTrip() throws {
        let store = InMemoryKeychainStore()
        try store.saveString("hello", for: "greeting")
        XCTAssertEqual(try store.readString("greeting"), "hello")
        XCTAssertNil(try store.readString("missing"))
    }
}
