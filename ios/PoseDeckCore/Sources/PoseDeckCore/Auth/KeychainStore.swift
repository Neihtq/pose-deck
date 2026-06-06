import Foundation
#if canImport(Security)
import Security
#endif

/// A tiny typed key/value store for small secrets (JWT, user id).
///
/// Abstracted behind a protocol so the production Keychain implementation can be
/// swapped for an in-memory fake in tests and previews (where the Security
/// framework Keychain is unavailable / undesirable).
public protocol KeychainStoring: Sendable {
    /// Persist `data` for `key`, overwriting any existing value. Throws on failure.
    func save(_ data: Data, for key: String) throws
    /// Read the stored `Data` for `key`, or `nil` if no value exists.
    func read(_ key: String) throws -> Data?
    /// Remove any stored value for `key`. A no-op if nothing is stored.
    func delete(_ key: String) throws
}

/// Errors surfaced by ``KeychainStore``.
public enum KeychainError: Error, Sendable, Equatable {
    /// A Keychain `SecItem*` call failed with the given OSStatus.
    case unexpectedStatus(OSStatus)
}

public extension KeychainStoring {
    /// Convenience: encode a `String` as UTF-8 and store it.
    func saveString(_ value: String, for key: String) throws {
        try save(Data(value.utf8), for: key)
    }

    /// Convenience: read a UTF-8 `String` for `key`, or `nil` if unset.
    func readString(_ key: String) throws -> String? {
        guard let data = try read(key) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

#if canImport(Security)
/// Keychain-backed ``KeychainStoring`` using the Security framework.
///
/// Stores items as generic passwords scoped by a `service` string so different
/// instances/apps don't collide. Values are accessible after first unlock so a
/// persisted session can be restored on relaunch.
public struct KeychainStore: KeychainStoring {
    /// The `kSecAttrService` namespace for all items written by this store.
    private let service: String

    /// The `kSecAttrAccessible` class applied to every item written by this store.
    ///
    /// `…ThisDeviceOnly` is deliberate: the values held here are device-bound
    /// session secrets (a bearer JWT and the encoded user record). The
    /// `ThisDeviceOnly` qualifier keeps them out of encrypted/unencrypted device
    /// backups and prevents restore onto a different device. There is no UX cost
    /// because the session is per-device and re-established on relaunch via
    /// `AuthService.restore()`.
    static var accessibility: CFString { kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly }

    public init(service: String = "com.posedeck.core.auth") {
        self.service = service
    }

    private func baseQuery(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    public func save(_ data: Data, for key: String) throws {
        // Delete-then-add keeps the write idempotent and avoids SecItemUpdate
        // attribute-merge surprises.
        try delete(key)

        var attributes = baseQuery(for: key)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = Self.accessibility

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    public func read(_ key: String) throws -> Data? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            return item as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    public func delete(_ key: String) throws {
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
#endif

/// In-memory ``KeychainStoring`` for tests, previews, and non-Apple platforms.
///
/// Thread-safe via actor-equivalent locking so it satisfies `Sendable` and can be
/// shared across tasks. Behaviour mirrors ``KeychainStore``: `save` overwrites,
/// `read` returns `nil` when unset, `delete` of a missing key is a no-op.
public final class InMemoryKeychainStore: KeychainStoring, @unchecked Sendable {
    private var storage: [String: Data] = [:]
    private let lock = NSLock()

    public init() {}

    public func save(_ data: Data, for key: String) throws {
        lock.lock(); defer { lock.unlock() }
        storage[key] = data
    }

    public func read(_ key: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        return storage[key]
    }

    public func delete(_ key: String) throws {
        lock.lock(); defer { lock.unlock() }
        storage[key] = nil
    }
}
