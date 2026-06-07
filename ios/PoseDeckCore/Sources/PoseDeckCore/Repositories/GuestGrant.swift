import Foundation

/// Pure decision helpers for the deck-sharing (`deck_guests`) grant flow.
///
/// Side-effect free and deterministic so the "is this grant a duplicate of an
/// existing one?" decision stays fully unit-testable, independent of the
/// (app-target) view models that call it. Mirrors the web reference guard
/// (`ShareDeckDialog.handleShare`'s `guests.some(...)` duplicate pre-check).
public enum GuestGrant {

    /// Whether `resolved` (the grant just written) duplicates an existing grant
    /// for the same user already present in `guests`.
    ///
    /// The just-written row is excluded by id (`$0.id != resolved.id`), so a
    /// match means a *prior* grant for the same user already exists — the share
    /// UI should surface "already shared" rather than imply a second grant landed.
    ///
    /// IMPORTANT: callers must pass a `guests` list that already reflects the
    /// just-written grant (i.e. a freshly reloaded mirror), NOT a pre-grant
    /// snapshot. Deciding against a stale snapshot races a concurrent grant for
    /// the same user: a second in-flight grant whose synchronous pre-check runs
    /// before the first grant's mirror reload would observe a `guests` array that
    /// lacks the first row and wrongly skip the friendly message
    /// (`swift-grantGuest-dup-check-stale`). The server composite-unique
    /// constraint still preserves data integrity either way; this guard is the
    /// UX message only, so it must read fresh state to fire reliably.
    public static func isDuplicate(resolved: DeckGuest, in guests: [DeckGuest]) -> Bool {
        guests.contains { $0.user == resolved.user && $0.id != resolved.id }
    }
}
