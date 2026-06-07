import XCTest
@testable import PoseDeckCore

/// Regression coverage for swift-5: a non-empty mirror that short-circuits a read
/// never adopted a remotely-added image nor dropped a remotely-deleted one, so a
/// second device (or a missed realtime event) served stale rows. The read path now
/// reconciles against remote on every online read via ``CardImageReconciler``.
final class CardImageReconcilerTests: XCTestCase {

    private func t(_ s: TimeInterval) -> Date { Date(timeIntervalSince1970: s) }

    private func img(_ id: String, card: String = "c", position: Int, file: String? = nil) -> CardImage {
        CardImage(id: id, card: card, position: position, file: file ?? "\(id).jpg", created: t(Double(position)))
    }

    // MARK: - Pure plan

    func testPlanInsertsRemoteAdditionAndDeletesRemoteRemoval() {
        // Mirror has i1; remote has i1 + a newly-added i2 and dropped nothing.
        let mirrored = [img("i1", position: 1)]
        let remote = [img("i1", position: 1), img("i2", position: 2)]
        let plan = CardImageReconciler.plan(remote: remote, mirrored: mirrored)
        XCTAssertEqual(plan.toInsert.map(\.id), ["i2"], "remotely-added image is inserted")
        XCTAssertTrue(plan.toDelete.isEmpty)
    }

    func testPlanDeletesRowMissingFromRemote() {
        // Mirror has i1 + i2; remote dropped i2 (deleted on another device).
        let mirrored = [img("i1", position: 1), img("i2", position: 2)]
        let remote = [img("i1", position: 1)]
        let plan = CardImageReconciler.plan(remote: remote, mirrored: mirrored)
        XCTAssertTrue(plan.toInsert.isEmpty)
        XCTAssertEqual(plan.toDelete, ["i2"], "row absent from remote is hard-deleted")
    }

    func testPlanNoChangeWhenAligned() {
        let mirrored = [img("i1", position: 1), img("i2", position: 2)]
        let remote = [img("i1", position: 1), img("i2", position: 2)]
        let plan = CardImageReconciler.plan(remote: remote, mirrored: mirrored)
        XCTAssertTrue(plan.toInsert.isEmpty)
        XCTAssertTrue(plan.toDelete.isEmpty)
    }

    // MARK: - apply() against a real LocalStore (mirror-non-empty-but-stale)

    func testApplyAdoptsRemoteAdditionIntoNonEmptyMirror() async {
        // The core swift-5 case: mirror already has a row, so the old code returned
        // it and never saw the remotely-added second image.
        let store = InMemoryLocalStore()
        await store.upsertCardImage(img("i1", position: 1))
        let remote = [img("i1", position: 1), img("i2", position: 2)]

        let result = await CardImageReconciler.apply(remote: remote, to: store, cardId: "c")
        XCTAssertEqual(result.map(\.id), ["i1", "i2"], "adopts the remotely-added image, sorted by position")
    }

    func testApplyDropsRemotelyDeletedRowFromNonEmptyMirror() async {
        // The cleanest defect: a server-deleted image lingered, minting a 404 URL.
        let store = InMemoryLocalStore()
        await store.upsertCardImage(img("i1", position: 1))
        await store.upsertCardImage(img("i2", position: 2))
        let remote = [img("i1", position: 1)] // i2 deleted remotely

        let result = await CardImageReconciler.apply(remote: remote, to: store, cardId: "c")
        XCTAssertEqual(result.map(\.id), ["i1"], "evicts the remotely-deleted image")
        let gone = await store.cardImage(id: "i2")
        XCTAssertNil(gone, "deleted row is hard-removed from the mirror")
    }

    func testApplyPreservesLocalBytesOverBytelessRemoteEcho() async {
        // Insert-by-id: an existing local row already holds the freshest filename,
        // so reconcile must not overwrite it with a byte-less remote row.
        let store = InMemoryLocalStore()
        await store.upsertCardImage(img("i1", position: 1, file: "real.jpg"))
        let remote = [img("i1", position: 1, file: nil)]

        _ = await CardImageReconciler.apply(remote: remote, to: store, cardId: "c")
        let kept = await store.cardImage(id: "i1")
        XCTAssertEqual(kept?.file, "real.jpg", "present row wins over a byte-less remote row")
    }

    func testApplyScopedToCard() async {
        // Reconcile for card c must not touch another card's images.
        let store = InMemoryLocalStore()
        await store.upsertCardImage(img("a1", card: "c", position: 1))
        await store.upsertCardImage(img("b1", card: "other", position: 1))
        let remote: [CardImage] = [] // c has no remote images now

        _ = await CardImageReconciler.apply(remote: remote, to: store, cardId: "c")
        let cImages = await store.cardImages(cardId: "c")
        let otherImages = await store.cardImages(cardId: "other")
        XCTAssertTrue(cImages.isEmpty, "c's rows reconciled away")
        XCTAssertEqual(otherImages.map(\.id), ["b1"], "another card's mirror untouched")
    }
}
