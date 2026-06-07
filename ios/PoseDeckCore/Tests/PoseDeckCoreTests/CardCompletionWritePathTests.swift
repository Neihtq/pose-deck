import XCTest
@testable import PoseDeckCore

/// Coverage for the M4 shoot-progress write path:
///  - `[FIX-m3]` `CardCompletion.deterministicId` shape/stability,
///  - `[FIX-C2]` outbox total ordering (create before update under equal clock),
///  - `[FIX-M1]` `OfflineWritePath.markCardCompletion` create/update branching,
///    LWW tie bypass for the user's own action, no network on the calling path,
///    and the deck-scoped `cardCompletions(cardIds:)` read.
final class CardCompletionWritePathTests: XCTestCase {

    private let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

    private func makePath(store: InMemoryLocalStore, outbox: InMemoryOutbox) -> OfflineWritePath {
        let now = fixedNow
        return OfflineWritePath(store: store, outbox: outbox, now: { now })
    }

    // MARK: - A1 [FIX-m3] deterministicId

    func testDeterministicIdMatchesPocketBaseShape() {
        let id = CardCompletion.deterministicId(card: "card01", user: "user01")
        XCTAssertEqual(id.count, 15)
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789")
        XCTAssertTrue(id.allSatisfy { allowed.contains($0) }, "id must satisfy ^[a-z0-9]{15}$")
    }

    func testDeterministicIdIsStable() {
        XCTAssertEqual(
            CardCompletion.deterministicId(card: "card01", user: "user01"),
            CardCompletion.deterministicId(card: "card01", user: "user01"),
            "same (card,user) → same id on every call/device/replay"
        )
    }

    func testDeterministicIdDistinctPerPair() {
        let a = CardCompletion.deterministicId(card: "card01", user: "user01")
        let b = CardCompletion.deterministicId(card: "card02", user: "user01")
        let c = CardCompletion.deterministicId(card: "card01", user: "user02")
        XCTAssertNotEqual(a, b, "different card → different id")
        XCTAssertNotEqual(a, c, "different user → different id")
        // Guard against a naive "card|user" vs "cardu|ser" collision.
        let d = CardCompletion.deterministicId(card: "a", user: "bc")
        let e = CardCompletion.deterministicId(card: "ab", user: "c")
        XCTAssertNotEqual(d, e, "delimiter must disambiguate concatenations")
    }

    // MARK: - A3 [FIX-C2] outbox total ordering

    func testOutboxOrdersCreateBeforeUpdateUnderIdenticalClock() async {
        let outbox = InMemoryOutbox()
        let stamp = fixedNow
        let create = OutboxEntry(
            type: .create, entity: "card_completions",
            payload: Data(#"{"id":"x","kind":"create"}"#.utf8),
            localTimestamp: stamp
        )
        let update = OutboxEntry(
            type: .update, entity: "card_completions",
            payload: Data(#"{"id":"x","kind":"update"}"#.utf8),
            localTimestamp: stamp // IDENTICAL clock
        )
        await outbox.enqueue(create)
        await outbox.enqueue(update)

        let pending = await outbox.pending()
        XCTAssertEqual(pending.map(\.type), [.create, .update],
                       "a create must precede its later update even at an equal timestamp")
    }

    // MARK: - A5 [FIX-M1] markCardCompletion

    func testFirstMarkIsCreateWithFullBodyAndOptimisticRow() async throws {
        let store = InMemoryLocalStore()
        let outbox = InMemoryOutbox()
        let path = makePath(store: store, outbox: outbox)

        let completion = try await path.markCardCompletion(cardId: "card01", userId: "user01", state: .done)
        let expectedId = CardCompletion.deterministicId(card: "card01", user: "user01")
        XCTAssertEqual(completion.id, expectedId)

        // Optimistic mirror row written immediately.
        let stored = await store.cardCompletion(id: expectedId)
        XCTAssertEqual(stored?.state, .done)
        XCTAssertEqual(stored?.card, "card01")
        XCTAssertEqual(stored?.user, "user01")

        // Exactly one create entry, full body.
        let pending = await outbox.pending()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.type, .create)
        XCTAssertEqual(pending.first?.entity, "card_completions")
        let body = try JSONSerialization.jsonObject(with: pending[0].payload) as? [String: Any]
        XCTAssertEqual(body?["id"] as? String, expectedId)
        XCTAssertEqual(body?["card"] as? String, "card01")
        XCTAssertEqual(body?["user"] as? String, "user01")
        XCTAssertEqual(body?["state"] as? String, "done")
        XCTAssertNotNil(body?["changed_at"])
    }

    func testSecondMarkSamePairIsUpdatePatchSameId() async throws {
        let store = InMemoryLocalStore()
        let outbox = InMemoryOutbox()
        let path = makePath(store: store, outbox: outbox)

        let first = try await path.markCardCompletion(cardId: "card01", userId: "user01", state: .done)
        let second = try await path.markCardCompletion(cardId: "card01", userId: "user01", state: .skipped)
        XCTAssertEqual(first.id, second.id, "same (card,user) → same deterministic id")

        let pending = await outbox.pending()
        XCTAssertEqual(pending.count, 2)
        XCTAssertEqual(pending[0].type, .create)
        XCTAssertEqual(pending[1].type, .update, "a state flip on an existing row is a PATCH")
        let patch = try JSONSerialization.jsonObject(with: pending[1].payload) as? [String: Any]
        XCTAssertEqual(patch?["id"] as? String, first.id)
        XCTAssertEqual(patch?["state"] as? String, "skipped")
        XCTAssertNil(patch?["card"], "PATCH must not re-send the create-only fields")
        // Final mirror state reflects the latest mark.
        let stored = await store.cardCompletion(id: first.id)
        XCTAssertEqual(stored?.state, .skipped)
    }

    func testTieBypassUnderConstantClockEndsDone() async throws {
        // `[FIX-M1]`: markDone → clear(pending) → markDone, all under a CONSTANT
        // injected clock (so every changedAt is identical). LWW would skip the
        // final equal-clock write as a tie no-op; the force-apply seam must not.
        let store = InMemoryLocalStore()
        let outbox = InMemoryOutbox()
        let path = makePath(store: store, outbox: outbox)

        let c = try await path.markCardCompletion(cardId: "card01", userId: "user01", state: .done)
        _ = try await path.markCardCompletion(cardId: "card01", userId: "user01", state: .pending)
        _ = try await path.markCardCompletion(cardId: "card01", userId: "user01", state: .done)

        let stored = await store.cardCompletion(id: c.id)
        XCTAssertEqual(stored?.state, .done, "tie bypass: final user action wins despite equal clock")
    }

    func testOfflinePathIssuesNoNetwork() async throws {
        // The write path touches only store + outbox; it must never hit the
        // network. We assert by using an APIClient whose session would record any
        // request — but the path holds no client at all, so simply assert the
        // mirror + queue are the only side effects.
        StubURLProtocol.shared.reset()
        let store = InMemoryLocalStore()
        let outbox = InMemoryOutbox()
        let path = makePath(store: store, outbox: outbox)

        _ = try await path.markCardCompletion(cardId: "card01", userId: "user01", state: .done)

        XCTAssertEqual(StubURLProtocol.shared.requests.count, 0, "no network on the calling path")
        let count = await outbox.count()
        XCTAssertEqual(count, 1)
        let stored = await store.cardCompletion(id: CardCompletion.deterministicId(card: "card01", user: "user01"))
        XCTAssertNotNil(stored)
    }

    func testCardCompletionsByCardIdsReturnsSubset() async throws {
        let store = InMemoryLocalStore()
        let outbox = InMemoryOutbox()
        let path = makePath(store: store, outbox: outbox)

        _ = try await path.markCardCompletion(cardId: "card01", userId: "user01", state: .done)
        _ = try await path.markCardCompletion(cardId: "card02", userId: "user01", state: .skipped)
        _ = try await path.markCardCompletion(cardId: "card03", userId: "user01", state: .done)

        let subset = await store.cardCompletions(cardIds: ["card01", "card03"])
        XCTAssertEqual(Set(subset.map(\.card)), ["card01", "card03"])
        XCTAssertEqual(subset.count, 2, "must not include card02")

        let none = await store.cardCompletions(cardIds: [])
        XCTAssertTrue(none.isEmpty)
    }
}
