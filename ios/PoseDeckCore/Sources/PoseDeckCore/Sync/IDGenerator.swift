import Foundation

/// Mints client-supplied record ids and idempotency keys for the offline-first
/// write path (M3 plan, invariant #1).
///
/// PocketBase accepts a caller-supplied 15-character alphanumeric `id` on
/// create (`POST .../records`). Minting the id on the client makes create
/// **idempotent**: if a 2xx ack is lost and the entry is replayed, the second
/// POST hits the already-existing id and PocketBase returns a 400 validation
/// error on `data.id` — which ``MutationSender`` classifies as success rather
/// than inserting a duplicate row. Because client id == server id, there is no
/// temp-id reconciliation: child foreign keys and queued payloads never need a
/// rewrite (invariant #2).
public enum IDGenerator {

    /// PocketBase's default record-id alphabet (lowercase + digits). Sticking to
    /// the same alphabet keeps client-minted ids indistinguishable from
    /// server-minted ones.
    static let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")

    /// Length of a PocketBase record id.
    static let idLength = 15

    /// Mint a fresh 15-character, PocketBase-shaped record id.
    ///
    /// Uses `SystemRandomNumberGenerator` (cryptographically adequate for an
    /// id-collision-avoidance use; not a security token). The 36^15 space makes
    /// an accidental collision with an existing record astronomically unlikely,
    /// and even if one occurred the lost-ack path treats the resulting 400 as a
    /// no-op success.
    public static func newClientId() -> String {
        var rng = SystemRandomNumberGenerator()
        return newClientId(using: &rng)
    }

    /// Seam for deterministic tests: mint an id from an injected RNG.
    public static func newClientId<R: RandomNumberGenerator>(using rng: inout R) -> String {
        var out = ""
        out.reserveCapacity(idLength)
        for _ in 0..<idLength {
            let index = Int.random(in: 0..<alphabet.count, using: &rng)
            out.append(alphabet[index])
        }
        return out
    }
}
