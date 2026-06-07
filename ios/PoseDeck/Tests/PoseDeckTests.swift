import XCTest
import PoseDeckCore
@testable import PoseDeck

/// Stub unit-test target for the app shell.
///
/// Logic-heavy tests live in the PoseDeckCore package (`swift test`). This
/// target exists so the app project has a wired-up test bundle for the
/// integration agent to grow UI/integration tests into.
final class PoseDeckTests: XCTestCase {
    /// AppConfig must always resolve to a usable URL, even when Info.plist is
    /// missing the key in the test bundle context.
    func testAppConfigFallsBackToDefaultBaseURL() {
        // In the test host the Info.plist key may be absent; the resolver must
        // still produce a valid URL rather than crashing.
        XCTAssertFalse(AppConfig.apiBaseURLString.isEmpty)
        XCTAssertNotNil(URL(string: AppConfig.apiBaseURLString))
    }
}

/// Reshoot (item 3) view-model behaviour: scoped completion reset + hydration
/// safety. These exercise the same runtime logic the simulator would; they run
/// on a host that can construct `@MainActor @Observable` view models.
@MainActor
final class ShootModeReshootTests: XCTestCase {

    private func makeCards(_ n: Int) -> [Card] {
        (0..<n).map { Card(id: "c\($0)", deck: "d1", position: ($0 + 1) * 1000, title: "Card \($0)") }
    }

    private func makeModel(
        cards: [Card],
        completionRepo: FakeCardCompletionRepository
    ) -> ShootModeViewModel {
        ShootModeViewModel(
            deck: Deck(id: "d1", owner: "u1", name: "Deck"),
            cards: cards,
            completionRepo: completionRepo,
            imageRepo: FakeCardImageRepository(),
            userId: "u1"
        )
    }

    /// On a 3-card deck where only some cards were touched, reshoot resets only
    /// the touched cards (M-scope: done ∪ skipped ∪ prior-fetch ids), and the
    /// mirror converges every reset card to `pending`. Untouched cards are not
    /// fabricated.
    func testReshootScopesResetToTouchedCards() async {
        let cards = makeCards(3)
        let repo = FakeCardCompletionRepository()
        let model = makeModel(cards: cards, completionRepo: repo)

        model.done()                         // c0 done
        model.skip()                         // c1 skipped
        // Drain the scheduled persists into the fake.
        try? await Task.sleep(nanoseconds: 100_000_000)

        await model.reshoot()

        // Session reset to the start.
        XCTAssertEqual(model.progressText, "Card 1 of 3")
        XCTAssertEqual(model.skippedCount, 0)
        XCTAssertFalse(model.isComplete)
        XCTAssertFalse(model.canUndo)

        // Only the touched cards (c0, c1) were written to pending; c2 untouched.
        let c0 = repo.byId[CardCompletion.deterministicId(card: "c0", user: "u1")]
        let c1 = repo.byId[CardCompletion.deterministicId(card: "c1", user: "u1")]
        let c2 = repo.byId[CardCompletion.deterministicId(card: "c2", user: "u1")]
        XCTAssertEqual(c0?.state, .pending)
        XCTAssertEqual(c1?.state, .pending)
        XCTAssertNil(c2, "untouched card must not have a fabricated pending row")
    }

    /// M-hydrate: after reshoot the local mirror reads `pending`, so even a fresh
    /// view-model instance hydrating via `load()` from the same repo stays reset
    /// (does not re-mark the old done card).
    func testReshootSurvivesFreshInstanceHydration() async {
        let cards = makeCards(3)
        let repo = FakeCardCompletionRepository()
        let model = makeModel(cards: cards, completionRepo: repo)

        model.done()                         // c0 done
        try? await Task.sleep(nanoseconds: 100_000_000)
        await model.reshoot()

        // A re-entered shoot screen builds a fresh view model whose load()
        // hydrates from the repo. Because reshoot wrote pending, nothing re-seeds.
        let fresh = makeModel(cards: cards, completionRepo: repo)
        await fresh.load()
        XCTAssertEqual(fresh.progressText, "Card 1 of 3")
        XCTAssertFalse(fresh.isComplete)
        XCTAssertEqual(fresh.skippedCount, 0)
    }

    /// M-hydrate: calling `load()` again on the same instance after reshoot does
    /// not revert the reset (didHydrate stays true; no re-seed).
    func testReshootThenLoadDoesNotReSeed() async {
        let cards = makeCards(2)
        let repo = FakeCardCompletionRepository()
        let model = makeModel(cards: cards, completionRepo: repo)

        model.done()
        model.done()                         // both done → complete
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(model.isComplete)

        await model.reshoot()
        XCTAssertFalse(model.isComplete)

        await model.load()                   // must not re-seed the old done state
        XCTAssertFalse(model.isComplete, "load() after reshoot must not revert the reset")
        XCTAssertEqual(model.progressText, "Card 1 of 2")
    }
}
