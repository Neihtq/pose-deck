import XCTest
@testable import PoseDeckCore

/// Regression coverage for SEC-1: the on-device mirror (SwiftData store +
/// `.externalStorage` image-blob sidecars) must be persisted under an
/// **explicit** file-protection class rather than relying on the implicit iOS
/// platform default.
///
/// `MirrorStoreProtection` is the PoseDeckCore policy the app target's
/// `LocalMirrorStore.makeContainer` applies to the store directory. These tests
/// run on macOS under `swift test`; file data-protection is inert there, so we
/// assert the policy *choice* (the right class is selected and the attribute is
/// applied to the directory we own) rather than kernel-level encryption.
final class MirrorStoreProtectionTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MirrorProtectionTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.removeItem(at: tempDir)
        }
    }

    /// The chosen class matches the Keychain's first-unlock accessibility so the
    /// background sync/pre-cache can read the mirror after first unlock — and is
    /// explicit, not the implicit default the finding flagged.
    func testFileProtectionClassIsFirstUnlock() {
        XCTAssertEqual(
            MirrorStoreProtection.fileProtection,
            .completeUntilFirstUserAuthentication
        )
    }

    /// Protecting a not-yet-existing directory creates it with the attribute.
    func testProtectCreatesDirectoryWhenMissing() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.path))
        try MirrorStoreProtection.protectDirectory(at: tempDir)
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }

    /// Protecting an already-existing directory updates its attributes (no throw,
    /// idempotent — the production path calls this on every container build).
    func testProtectExistingDirectoryIsIdempotent() throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try MirrorStoreProtection.protectDirectory(at: tempDir)
        // A second call on the now-existing directory must not throw.
        XCTAssertNoThrow(try MirrorStoreProtection.protectDirectory(at: tempDir))
    }

    /// On a data-protection-capable filesystem the attribute is reported back as
    /// the class we set; on platforms without data protection (macOS CI here) it
    /// is reported as `nil`. Either is acceptable — what must NOT happen is a
    /// *different* class being recorded.
    func testProtectionClassIsNeverADifferentClass() throws {
        try MirrorStoreProtection.protectDirectory(at: tempDir)
        let reported = MirrorStoreProtection.protectionClass(of: tempDir)
        if let reported {
            XCTAssertEqual(reported, .completeUntilFirstUserAuthentication)
        }
    }
}
