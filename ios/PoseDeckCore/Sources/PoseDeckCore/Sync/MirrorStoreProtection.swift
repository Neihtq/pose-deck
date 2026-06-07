import Foundation

/// At-rest file-protection policy for the on-device mirror (SwiftData store +
/// `.externalStorage` image-blob sidecars).
///
/// ## Why this exists
/// The mirror persists every synced deck/card row and pre-cached JPEG bytes to
/// disk. On a passcode-protected device iOS *defaults* these files to
/// `completeUntilFirstUserAuthentication`, but that default is implicit: it
/// depends on the device having a passcode and on us not having relied on a
/// different default. We make the class **explicit and deterministic** here so
/// the on-disk content is encrypted at rest under a documented policy rather
/// than an inherited platform default (SEC-1 hardening).
///
/// ## Class choice (and why it differs from the Keychain)
/// We deliberately pick the *file* class
/// ``FileProtectionType/completeUntilFirstUserAuthentication`` to match the
/// Keychain item's `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
/// accessibility (see `KeychainStore.accessibility`): both keep data readable by
/// background sync/pre-cache after the first post-boot unlock.
///
/// The mirror is *not* given the stricter `…ThisDeviceOnly` treatment the
/// Keychain uses, on purpose: the Keychain holds a portable bearer credential
/// (the JWT) that must never leave the device or restore elsewhere, whereas the
/// mirror holds the user's own authored shotlist content and their own
/// downloaded images — self-authored content that is legitimately allowed to
/// follow the user through an encrypted device backup/restore. The asymmetry is
/// intentional, not an oversight.
public enum MirrorStoreProtection {

    /// The explicit file-protection class applied to the mirror's store
    /// directory (and therefore to the SQLite store + external-storage blobs
    /// created inside it).
    ///
    /// Keep this aligned with the Keychain's first-unlock accessibility so the
    /// background sync engine and pre-cache can read the mirror after first
    /// unlock without prompting.
    public static var fileProtection: FileProtectionType {
        .completeUntilFirstUserAuthentication
    }

    /// Apply ``fileProtection`` to the directory that will hold the mirror's
    /// store (creating the directory first if needed).
    ///
    /// Setting the attribute on the *directory* means files SwiftData creates
    /// inside it — the `.sqlite` store, its `-wal`/`-shm` companions, and the
    /// `.externalStorage` image-blob sidecars — inherit the protection class on
    /// creation, so we don't have to chase individual files after the fact.
    ///
    /// On platforms without data protection (e.g. macOS, used by `swift test`)
    /// the attribute is accepted but inert; the call still creates the
    /// directory and records the intended class, so the policy is exercised by
    /// tests.
    ///
    /// - Parameters:
    ///   - directory: the directory to protect (typically the mirror store's
    ///     parent directory).
    ///   - fileManager: injectable for tests; defaults to `.default`.
    public static func protectDirectory(
        at directory: URL,
        fileManager: FileManager = .default
    ) throws {
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: fileProtection]
            )
        } else {
            try fileManager.setAttributes(
                [.protectionKey: fileProtection],
                ofItemAtPath: directory.path
            )
        }
    }

    /// Read back the protection class currently set on `directory`, or `nil` if
    /// the platform/filesystem does not report one. Used by tests to assert the
    /// policy was applied; production code has no reason to call this.
    public static func protectionClass(
        of directory: URL,
        fileManager: FileManager = .default
    ) -> FileProtectionType? {
        let attrs = try? fileManager.attributesOfItem(atPath: directory.path)
        return attrs?[.protectionKey] as? FileProtectionType
    }
}
