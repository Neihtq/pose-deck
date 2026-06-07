import Foundation

/// Data-access layer for the `deck_guests` collection (ARCHITECTURE.md §3.5).
///
/// Wraps ``APIClient``'s generic CRUD. Mirrors the web `guestApi.ts` reference.
///
/// `deck_guests` carries no LWW clock (insert-on-grant / hard-delete-on-revoke);
/// the optimistic write path and realtime merge live in ``OfflineWritePath`` and
/// ``SyncEngine``. This repository is the *read/backfill* surface (list every
/// visible guest row) plus the email→user-id resolution the share UI needs.
public struct DeckGuestRepository: Sendable {

    private let client: APIClient
    private let collection = "deck_guests"
    private let usersCollection = "users"

    /// The authenticated user's id — needed to resolve an email lookup (the
    /// matched user's fields are hidden by `viewRule`, so the matched row is
    /// identified positionally as "the one that isn't me").
    private let currentUserId: String

    public init(client: APIClient, currentUserId: String) {
        self.client = client
        self.currentUserId = currentUserId
    }

    // MARK: - Read

    /// List *every* `deck_guests` row the current user can see across all pages.
    ///
    /// The `listRule` scopes results to rows where the caller is the deck owner
    /// or the granted user, so this returns exactly the grants relevant to the
    /// session (mirrors the web `getFullList`).
    public func listGuests() async throws -> [DeckGuest] {
        try await client.listAll(
            DeckGuest.self,
            collection: collection,
            perPage: 200
        )
    }

    // MARK: - Email resolution

    /// Resolve a guest's user id by exact email, or `nil` if no such account.
    ///
    /// VERIFIED against live PB: the relaxed `users.listRule`
    /// (`id = @request.auth.id || (@request.auth.id != "" && email = @request.query.email)`)
    /// matches a row by the `email` **query param** — NOT a filter clause. The
    /// matched user's `email` (and other fields) are hidden by `viewRule` (null
    /// in the response), so adding `filter: 'email = "..."'` would exclude the
    /// row (the filter evaluates the null field). We therefore pass ONLY the
    /// `email` query param and let the rule do the matching.
    ///
    /// The endpoint returns the caller's own row PLUS the matched row (both
    /// satisfy the listRule). We resolve the guest as the item whose `id` is not
    /// the authenticated user's id. A lookup of the caller's own email returns
    /// only the caller's row → no foreign id → `nil` (the share UI also guards
    /// self-share up front).
    public func resolveUser(byEmail email: String) async throws -> String? {
        let response = try await client.list(
            User.self,
            collection: usersCollection,
            perPage: 200,
            extraQuery: ["email": email]
        )
        return response.items.first(where: { $0.id != currentUserId })?.id
    }
}
