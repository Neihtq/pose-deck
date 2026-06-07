import XCTest
@testable import PoseDeckCore

/// Regression guard for finding `swift-2`.
///
/// The iOS **app target** is built in the Swift 6 language mode (project.yml
/// `SWIFT_VERSION: "6.0"`) so its concurrent sync/shoot glue — `SyncCoordinator`,
/// the `@MainActor` mirror repositories, the `SwiftDataLocalStore` actor, the
/// `BackgroundRefresh` handler, and the `ShootModeViewModel` — has its
/// data-race-safety actually *enforced* at compile time. That enforcement only
/// works if the `PoseDeckCore` value types those layers pass **across actor
/// boundaries** stay `Sendable`. If a future edit drops `Sendable` from one of
/// them, the app's Swift 6 build breaks with a cross-actor "non-Sendable"
/// error — but the simulator cannot run here, so the app build is the only place
/// that would be caught, and only if someone happens to recompile the app.
///
/// These tests pull that contract down into the unit-testable core: each model
/// that crosses an isolation boundary in the sync/shoot path is required to be
/// `Sendable` via a generic constraint, so `swift test` fails fast (with a clear
/// message) the moment the conformance is lost — independent of the app build.
///
/// NOTE on scope: the actual language-mode switch and the app-glue concurrency
/// fixes (ShootModeViewModel `persist` op made `@MainActor`, BackgroundRefresh
/// task isolation, MirrorChangeTicker nonisolated deinit teardown) live in the
/// app target and are verified by `xcodebuild ... build` under Swift 6, not by
/// this package's `swift test` (no simulator in this environment).
final class ConcurrencyContractTests: XCTestCase {

    /// Compile-time witness: `T` must be `Sendable`. Calling it with a type that
    /// is not `Sendable` fails to compile, which is the regression we guard.
    private func requireSendable<T: Sendable>(_ type: T.Type) {
        XCTAssertNotNil(type)
    }

    /// The models the app sends across actor boundaries (mirror repos hand these
    /// between the `@MainActor` UI layer and the `SwiftDataLocalStore` actor /
    /// background `Task`s) must all remain `Sendable`.
    func testCrossActorModelsAreSendable() {
        requireSendable(Card.self)
        requireSendable(Deck.self)
        requireSendable(CardCompletion.self)
        requireSendable(CardImage.self)
        requireSendable(DeckGuest.self)
        requireSendable(User.self)
    }

    /// `ShootSession` (and its `UndoFrame`) is the value type `ShootModeViewModel`
    /// (a `@MainActor` `@Observable`) mutates and snapshots; the shoot persist
    /// path and prefetch `Task`s rely on it being safe to capture, so it must
    /// stay `Sendable`.
    func testShootSessionIsSendable() {
        requireSendable(ShootSession.self)
        requireSendable(ShootSession.UndoFrame.self)
    }

    /// Sanity: a real instance of the completion model — the payload the
    /// `ShootModeViewModel.persist(...)` op produces and the app's `@MainActor`
    /// repositories return across `await` boundaries — round-trips through a
    /// `Sendable`-constrained generic context unchanged.
    func testCardCompletionFlowsThroughSendableBoundary() {
        let completion = CardCompletion(
            id: CardCompletion.deterministicId(card: "card1", user: "user1"),
            card: "card1",
            user: "user1",
            state: .done,
            changedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertEqual(passThroughSendable(completion), completion)
    }

    /// Forces `Value: Sendable`; returns the value unchanged.
    private func passThroughSendable<Value: Sendable>(_ value: Value) -> Value {
        value
    }
}
