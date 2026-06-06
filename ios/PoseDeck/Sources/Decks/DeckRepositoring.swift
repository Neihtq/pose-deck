import Foundation
import PoseDeckCore

/// App-side abstraction over ``DeckRepository`` so SwiftUI view models can be
/// driven by an in-memory fake in `#Preview`s and (future) view-model tests
/// without touching the network.
///
/// ``PoseDeckCore/DeckRepository`` is a concrete `struct`; this protocol mirrors
/// the subset of its surface the deck-list / deck-detail screens use. The real
/// repository conforms via an extension below, so production code injects the
/// genuine `DeckRepository` while previews inject `FakeDeckRepository`.
@MainActor
protocol DeckRepositoring {
    func listDecks() async throws -> [Deck]
    func getDeck(id: String) async throws -> Deck
    func listTrashedDecks() async throws -> [Deck]

    @discardableResult
    func createDeck(name: String, shootDate: Date?, ownerId: String) async throws -> Deck
    @discardableResult
    func renameDeck(id: String, name: String) async throws -> Deck
    @discardableResult
    func setShootDate(id: String, shootDate: Date?) async throws -> Deck
    @discardableResult
    func softDeleteDeck(id: String) async throws -> Deck
    @discardableResult
    func restoreDeck(id: String) async throws -> Deck
    @discardableResult
    func duplicateDeck(id: String, ownerId: String) async throws -> Deck
}

/// Bridge the core value-type repository onto the app protocol. `DeckRepository`
/// is `Sendable` and its methods are non-isolated `async`; calling them from the
/// `@MainActor` conformance is fine (they hop to the actor-isolated `APIClient`).
extension DeckRepository: DeckRepositoring {}
