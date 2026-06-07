import XCTest
@testable import PoseDeckCore

/// Coverage for ``MirrorMerge`` / ``MirrorRow`` (M3 plan, STEP 10): the SwiftData
/// mirror LWW decision must match ``LWW`` (invariant #3).
final class LocalMirrorMappingTests: XCTestCase {

    private func t(_ s: TimeInterval) -> Date { Date(timeIntervalSince1970: s) }

    // MARK: - Date-overload truth table

    func testNoExistingRowApplies() {
        XCTAssertTrue(MirrorMerge.shouldApply(incoming: t(1), existing: nil))
    }

    func testStrictlyNewerApplies() {
        XCTAssertTrue(MirrorMerge.shouldApply(incoming: t(2), existing: t(1)))
    }

    func testOlderLoses() {
        XCTAssertFalse(MirrorMerge.shouldApply(incoming: t(1), existing: t(2)))
    }

    func testTieIsSkipped() {
        XCTAssertFalse(MirrorMerge.shouldApply(incoming: t(5), existing: t(5)))
    }

    func testNilIncomingClockApplies() {
        // An incoming server row that carried no client clock applies over a
        // clocked existing row (freshest known server state).
        XCTAssertTrue(MirrorMerge.shouldApply(incoming: nil, existing: t(9)))
    }

    func testNilExistingClockApplies() {
        XCTAssertTrue(MirrorMerge.shouldApply(incoming: t(1), existing: nil))
    }

    // MARK: - MirrorRow overload parity with LWW

    private struct FakeRow: MirrorRow {
        let mirrorOrderingTimestamp: Date?
    }

    func testRowOverloadMatchesDateOverload() {
        let newer = FakeRow(mirrorOrderingTimestamp: t(2))
        let older = FakeRow(mirrorOrderingTimestamp: t(1))
        XCTAssertTrue(MirrorMerge.shouldApply(incoming: newer, over: older))
        XCTAssertFalse(MirrorMerge.shouldApply(incoming: older, over: newer))
        XCTAssertTrue(MirrorMerge.shouldApply(incoming: newer, over: nil))
    }

    /// The mirror decision must agree with the domain ``LWW`` for clocked rows.
    func testParityWithDomainLWW() {
        let old = Deck(id: "d", owner: "u", name: "old", clientUpdatedAt: t(1))
        let new = Deck(id: "d", owner: "u", name: "new", clientUpdatedAt: t(2))
        XCTAssertEqual(
            LWW.shouldApply(incoming: new, over: old),
            MirrorMerge.shouldApply(incoming: new.clientUpdatedAt, existing: old.clientUpdatedAt)
        )
        XCTAssertEqual(
            LWW.shouldApply(incoming: old, over: new),
            MirrorMerge.shouldApply(incoming: old.clientUpdatedAt, existing: new.clientUpdatedAt)
        )
    }
}
