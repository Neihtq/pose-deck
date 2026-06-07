import Foundation
import PoseDeckCore

/// App-side abstraction over the deck-sharing (`deck_guests`) read/write path
/// (mirrors ``DeckRepositoring``) so the share UI / deck-detail view model can be
/// driven by an in-memory fake in `#Preview`s and tests.
///
/// `listGuests` serves the local mirror (deck-scoped); `grantGuest` resolves the
/// email to a user id then writes optimistically + enqueues a create; `revokeGuest`
/// hard-removes the mirror row + enqueues a delete.
@MainActor
protocol DeckGuestRepositoring {
    /// Current guests of a deck, oldest grant first.
    func listGuests(deckId: String) async throws -> [DeckGuest]
    /// Grant access by exact email. Returns the optimistic ``DeckGuest`` on
    /// success, or throws ``DeckGuestRepositoringError/userNotFound`` when no
    /// account matches the email.
    @discardableResult
    func grantGuest(deckId: String, email: String) async throws -> DeckGuest
    /// Revoke an existing guest grant.
    func revokeGuest(_ guest: DeckGuest) async throws
}

/// Errors surfaced by ``DeckGuestRepositoring``.
enum DeckGuestRepositoringError: Error, Equatable {
    /// No user account matches the supplied email.
    case userNotFound
}

/// In-memory ``DeckGuestRepositoring`` for `#Preview`s and unit tests.
@MainActor
final class FakeDeckGuestRepository: DeckGuestRepositoring {
    /// Guests keyed by id.
    var byId: [String: DeckGuest]
    /// Emails the fake will resolve to a user id (email → user id).
    var knownUsers: [String: String]
    var error: Error?

    init(guests: [DeckGuest] = [], knownUsers: [String: String] = [:], error: Error? = nil) {
        self.byId = Dictionary(uniqueKeysWithValues: guests.map { ($0.id, $0) })
        self.knownUsers = knownUsers
        self.error = error
    }

    func listGuests(deckId: String) async throws -> [DeckGuest] {
        if let error { throw error }
        return byId.values.filter { $0.deck == deckId }
            .sorted { ($0.grantedAt ?? .distantPast) < ($1.grantedAt ?? .distantPast) }
    }

    @discardableResult
    func grantGuest(deckId: String, email: String) async throws -> DeckGuest {
        if let error { throw error }
        guard let userId = knownUsers[email] else { throw DeckGuestRepositoringError.userNotFound }
        let guest = DeckGuest(id: "g-\(deckId)-\(userId)", deck: deckId, user: userId, grantedAt: Date())
        byId[guest.id] = guest
        return guest
    }

    func revokeGuest(_ guest: DeckGuest) async throws {
        if let error { throw error }
        byId[guest.id] = nil
    }
}
