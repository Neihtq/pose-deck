import Foundation

/// Pure decision logic for which decks the background pre-cache should pull into
/// the offline mirror, and when the next refresh should run (M3 plan, STEP 10).
///
/// Kept here in PoseDeckCore — away from any SwiftData / `BGTaskScheduler`
/// surface — so the 48-hour-window, pinned-union, and exclusion rules are
/// deterministically unit-testable (`swift test`) without a device.
///
/// The two rules:
///  - **Time window**: decks whose `shootDate` falls within the next `window`
///    (default 48h) from `now` are pre-cached so a photographer walks into a
///    shoot with the deck already on-device.
///  - **Pinned union**: decks the user explicitly pinned for offline use are
///    always pre-cached, regardless of date.
///  - **Exclusions**: soft-deleted decks (and any caller-supplied id) are never
///    pre-cached.
public enum PrecachePlan {

    /// The default look-ahead window for date-driven pre-cache: 48 hours.
    public static let defaultWindow: TimeInterval = 48 * 60 * 60

    /// Compute the set of deck ids to pre-cache.
    ///
    /// A deck is included when **either** it is pinned **or** its `shootDate` is
    /// in `[now, now + window]` (inclusive of the boundary). Soft-deleted decks
    /// and ids in `excluding` are never included even if pinned (a revoked /
    /// trashed deck must not linger offline).
    ///
    /// - Parameters:
    ///   - decks: the candidate decks (typically the user's live decks).
    ///   - pinnedIds: deck ids the user pinned for offline.
    ///   - now: the reference instant.
    ///   - window: the look-ahead window (default 48h).
    ///   - excluding: deck ids to force-exclude (e.g. already-precached, revoked).
    /// - Returns: the deck ids to pre-cache, in the input `decks` order so the
    ///   result is stable/testable.
    public static func decksToPrecache(
        decks: [Deck],
        pinnedIds: Set<String> = [],
        now: Date,
        window: TimeInterval = defaultWindow,
        excluding: Set<String> = []
    ) -> [String] {
        let windowEnd = now.addingTimeInterval(window)
        return decks.compactMap { deck -> String? in
            // Never pre-cache a soft-deleted or explicitly-excluded deck.
            if deck.deletedAt != nil { return nil }
            if excluding.contains(deck.id) { return nil }

            if pinnedIds.contains(deck.id) { return deck.id }

            if let shootDate = deck.shootDate, shootDate >= now, shootDate <= windowEnd {
                return deck.id
            }
            return nil
        }
    }

    /// The next time a background refresh should be scheduled.
    ///
    /// Returns the earliest upcoming deck `shootDate` that is still in the future
    /// (so the refresh wakes just before the next shoot), clamped to at least
    /// `minInterval` from `now` (BGTaskScheduler won't run more often than the
    /// system allows, and we don't want a tight loop). When no future shoot
    /// exists, falls back to `now + defaultInterval`.
    ///
    /// - Parameters:
    ///   - decks: the candidate decks.
    ///   - now: the reference instant.
    ///   - minInterval: floor on how soon the next refresh may be (default 1h).
    ///   - defaultInterval: used when there is no upcoming shoot (default 24h).
    public static func nextRefreshDate(
        decks: [Deck],
        now: Date,
        minInterval: TimeInterval = 60 * 60,
        defaultInterval: TimeInterval = 24 * 60 * 60
    ) -> Date {
        let upcoming = decks
            .filter { $0.deletedAt == nil }
            .compactMap { $0.shootDate }
            .filter { $0 > now }
            .min()

        let target = upcoming ?? now.addingTimeInterval(defaultInterval)
        let floor = now.addingTimeInterval(minInterval)
        return max(target, floor)
    }
}
