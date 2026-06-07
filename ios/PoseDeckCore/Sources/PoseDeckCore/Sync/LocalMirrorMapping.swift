import Foundation

/// A row in the on-device SwiftData mirror that carries an LWW ordering clock,
/// so the merge rule (§4.3) can be applied uniformly to either a domain
/// ``SyncRecord`` or a persisted `@Model` row (M3 plan, STEP 10).
///
/// The app's `@Model` classes (`LocalDeck`, `LocalCard`, …) conform to this so
/// the SwiftData mirror and the in-memory engine share one merge decision and
/// can never diverge. Images/guests have no clock and report `nil`.
public protocol MirrorRow {
    /// The LWW ordering timestamp for this row, or `nil` when the collection has
    /// no LWW clock (images/guests — see ``SyncRecord``).
    var mirrorOrderingTimestamp: Date? { get }
}

/// The LWW merge decision for the SwiftData mirror (M3 plan, STEP 10 /
/// invariant #3).
///
/// This mirrors ``LWW`` but is expressed over the ``MirrorRow`` protocol so the
/// app layer can decide "should this incoming server/echo value overwrite the
/// persisted row?" using the *persisted* row's clock — without first decoding
/// it back into a domain `struct`. The semantics are identical to ``LWW``:
///  - no existing row → apply (insert),
///  - either clock `nil` → apply (no clock to lose by; self-echo of our own
///    in-flight writes is suppressed separately, invariant #4),
///  - both clocks present → apply iff incoming is **strictly newer** (ties skip).
public enum MirrorMerge {

    /// Whether `incoming` should overwrite the persisted `existing` row.
    public static func shouldApply(incoming: Date?, existing: Date?) -> Bool {
        guard let existing else { return true }
        guard let incoming else { return true }
        // A present existing clock with a nil incoming clock means the incoming
        // value carried no client clock — apply (it's the freshest server state).
        return incoming > existing
    }

    /// Convenience overload taking two ``MirrorRow``s.
    public static func shouldApply(incoming: MirrorRow, over existing: MirrorRow?) -> Bool {
        shouldApply(incoming: incoming.mirrorOrderingTimestamp, existing: existing?.mirrorOrderingTimestamp)
    }
}
