import XCTest
import SwiftData
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

    /// `[GAUNTLET-3]` regression: a done()/skip() persist is still queued (we do
    /// NOT drain it with the 100ms sleep the other tests use) when reshoot() runs.
    /// reshoot() must cancel that in-flight persist BEFORE resetting, so the
    /// touched card converges to `.pending` and stays there — a queued markDone
    /// running after resetCompletions would otherwise re-strand it as `.done`.
    /// Without fix #3 the markDone interleaves during reshoot's awaits and wins.
    func testReshootCancelsInFlightPersistBeforeReset() async {
        let cards = makeCards(3)
        let repo = FakeCardCompletionRepository()
        let model = makeModel(cards: cards, completionRepo: repo)

        model.done()                         // c0 done — persist SCHEDULED, not yet run
        model.skip()                         // c1 skipped — persist SCHEDULED, not yet run
        // NO drain sleep here: the persists are still queued on the scheduler.
        await model.reshoot()

        // Give any (incorrectly) surviving persist task ample time to run and
        // re-strand a card — with fix #3 it was cancelled and nothing fires.
        try? await Task.sleep(nanoseconds: 100_000_000)

        let c0 = repo.byId[CardCompletion.deterministicId(card: "c0", user: "u1")]
        let c1 = repo.byId[CardCompletion.deterministicId(card: "c1", user: "u1")]
        XCTAssertEqual(c0?.state, .pending, "c0 must converge to pending, not be re-stranded as done")
        XCTAssertEqual(c1?.state, .pending, "c1 must converge to pending, not be re-stranded as skipped")

        // A subsequent fresh load() must not re-seed the touched cards as done/skipped.
        let fresh = makeModel(cards: cards, completionRepo: repo)
        await fresh.load()
        XCTAssertEqual(fresh.progressText, "Card 1 of 3")
        XCTAssertFalse(fresh.isComplete)
        XCTAssertEqual(fresh.skippedCount, 0)
    }
}

// MARK: - New-card image staging (pick before save, upload on create)

/// Records uploads and serves a canned image list, like RecordingImageRepository
/// but minimal for the staging tests.
@MainActor
private final class StagingImageRepo: ImageRepositing {
    nonisolated var maxImagesPerCard: Int { 5 }
    private(set) var uploads: [(cardId: String, position: Int)] = []
    var failUploads = false

    func listCardImages(cardId: String) async throws -> [CardImage] { [] }
    func fileURL(for image: CardImage) async throws -> URL {
        URL(string: "https://example.invalid/\(image.id)")!
    }
    @discardableResult
    func uploadCardImage(cardId: String, data: Data, position: Int) async throws -> CardImage {
        if failUploads { throw URLError(.notConnectedToInternet) }
        uploads.append((cardId: cardId, position: position))
        return CardImage(id: "up-\(uploads.count)", card: cardId, position: position)
    }
    func deleteCardImage(id: String) async throws {}
}

/// `CardImagesViewModel` staging behaviour (UX: add images while creating a new
/// card). With no card id yet, picks are staged in memory; `flushStaged` uploads
/// them once the card exists. These run the real compressor on the simulator
/// host (UIKit available), so they need a tiny valid image to compress.
@MainActor
final class CardImageStagingTests: XCTestCase {

    /// A 2x2 PNG re-encoded as the bytes the picker would hand us. ImageIO can
    /// decode this, so `compressor.compress` succeeds in `addImage`.
    private func tinyImageData() -> Data {
        let size = CGSize(width: 8, height: 8)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            UIColor.systemTeal.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        return image.jpegData(compressionQuality: 0.9)!
    }

    func testPicksAreStagedWhenNoCardYet() async {
        let repo = StagingImageRepo()
        let model = CardImagesViewModel(cardId: nil, repository: repo)

        await model.addImage(data: tinyImageData())

        XCTAssertEqual(model.stagedImages.count, 1, "a pick with no card id stages locally")
        XCTAssertTrue(model.images.isEmpty, "nothing is persisted yet")
        XCTAssertEqual(model.imageCount, 1, "count reflects the staged image")
        XCTAssertTrue(repo.uploads.isEmpty, "no upload happens before the card exists")
    }

    func testFlushStagedUploadsAllInOrder() async {
        let repo = StagingImageRepo()
        let model = CardImagesViewModel(cardId: nil, repository: repo)
        await model.addImage(data: tinyImageData())
        await model.addImage(data: tinyImageData())

        let ok = await model.flushStaged(cardId: "card-new")

        XCTAssertTrue(ok, "all staged images uploaded")
        XCTAssertEqual(repo.uploads.count, 2, "both staged images uploaded on create")
        XCTAssertEqual(repo.uploads.map(\.cardId), ["card-new", "card-new"])
        XCTAssertEqual(repo.uploads.map(\.position), [1, 2], "uploaded in pick order")
        XCTAssertEqual(model.stagedImages.count, 0, "staging buffer cleared on success")
        XCTAssertEqual(model.images.count, 2, "uploaded images now persisted")
        XCTAssertEqual(model.imageCount, 2)
    }

    func testCardWithIdUploadsImmediatelyNotStaged() async {
        let repo = StagingImageRepo()
        let model = CardImagesViewModel(cardId: "existing", repository: repo)

        await model.addImage(data: tinyImageData())

        XCTAssertEqual(repo.uploads.count, 1, "an existing card uploads immediately")
        XCTAssertTrue(model.stagedImages.isEmpty, "nothing staged when the card already exists")
        XCTAssertEqual(model.images.count, 1)
    }

    func testFlushKeepsStagedOnUploadFailure() async {
        let repo = StagingImageRepo()
        repo.failUploads = true
        let model = CardImagesViewModel(cardId: nil, repository: repo)
        await model.addImage(data: tinyImageData())

        let ok = await model.flushStaged(cardId: "card-new")

        XCTAssertFalse(ok, "flush reports failure")
        XCTAssertEqual(model.stagedImages.count, 1, "staged image retained so the user can retry — not silently lost")
        XCTAssertNotNil(model.errorMessage)
    }

    func testStagedImageRespectsCapAcrossStagedAndPersisted() async {
        let repo = StagingImageRepo()
        let model = CardImagesViewModel(cardId: nil, repository: repo)
        for _ in 0..<5 { await model.addImage(data: tinyImageData()) }
        XCTAssertEqual(model.stagedImages.count, 5)

        await model.addImage(data: tinyImageData())  // 6th — over the cap

        XCTAssertEqual(model.stagedImages.count, 5, "cap enforced on staged images")
        XCTAssertTrue(model.atImageLimit)
        XCTAssertNotNil(model.errorMessage)
    }
}

// MARK: - Fix #4: duplicate-deck image copy (web parity)

/// Records every `uploadCardImage` call so a test can assert images were copied
/// onto the copy card at the right position. The list/url stubs return canned
/// data per source card so `copyImages` can run end-to-end without the network.
@MainActor
final class RecordingImageRepository: ImageRepositing {
    nonisolated var maxImagesPerCard: Int { 5 }

    /// Source-card images, keyed by card id, returned by `listCardImages`.
    var imagesByCard: [String: [CardImage]]
    /// Every upload as `(cardId, position)`, in call order.
    private(set) var uploads: [(cardId: String, position: Int)] = []

    init(imagesByCard: [String: [CardImage]] = [:]) { self.imagesByCard = imagesByCard }

    func listCardImages(cardId: String) async throws -> [CardImage] { imagesByCard[cardId] ?? [] }

    func fileURL(for image: CardImage) async throws -> URL {
        // A real file:// URL so `downloadProtected` (which routes through a real
        // URLSession) returns bytes without any network. URLSession serves
        // file:// reliably; data: URLs interact poorly with the reload policy.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("posedeck-test-\(image.id).jpg")
        try? Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: url)
        return url
    }

    @discardableResult
    func uploadCardImage(cardId: String, data: Data, position: Int) async throws -> CardImage {
        uploads.append((cardId: cardId, position: position))
        return CardImage(id: "uploaded-\(uploads.count)", card: cardId, position: position)
    }

    func deleteCardImage(id: String) async throws {}
}

@MainActor
final class DuplicateDeckImageCopyTests: XCTestCase {

    /// Build a MirrorDeckRepository over an in-memory mirror with the supplied
    /// image deps. `cardExists` controls the server-side existence probe.
    private func makeRepo(
        imageRepo: ImageRepositing?,
        cardExists: @escaping @Sendable (String) -> Bool
    ) throws -> MirrorDeckRepository {
        let container = try LocalMirrorStore.makeContainer(inMemory: true)
        let store = SwiftDataLocalStore(container: container)
        let outbox = SwiftDataOutbox(container: container)
        return MirrorDeckRepository(
            store: store,
            outbox: outbox,
            currentUserId: "u1",
            imageRepo: imageRepo,
            awaitOutboxDrain: imageRepo == nil ? nil : { /* no-op drain for the unit test */ },
            cardExistsRemotely: imageRepo == nil ? nil : { id in cardExists(id) }
        )
    }

    /// When the copy card exists server-side, each source image is uploaded onto
    /// the copy card preserving its position. Drives `copyDeckImages(pairs:)`
    /// directly (no detached-task timing).
    func testCopyDeckImagesUploadsEachSourceImageAtPosition() async throws {
        let source = Card(id: "src1", deck: "d1", position: 1000, title: "Source")
        let copy = Card(id: "copy1", deck: "d2", position: 1000, title: "Source (copy)")
        let recorder = RecordingImageRepository(imagesByCard: [
            "src1": [
                CardImage(id: "i1", card: "src1", position: 1000),
                CardImage(id: "i2", card: "src1", position: 2000),
                CardImage(id: "i3", card: "src1", position: 3000),
            ]
        ])
        let repo = try makeRepo(imageRepo: recorder, cardExists: { _ in true })

        await repo.copyDeckImages(pairs: [(source: source, copy: copy)])

        XCTAssertEqual(recorder.uploads.count, 3, "every source image must be copied")
        XCTAssertEqual(recorder.uploads.map(\.cardId), ["copy1", "copy1", "copy1"])
        XCTAssertEqual(recorder.uploads.map(\.position), [1000, 2000, 3000],
                       "each image must keep its source position on the copy card")
    }

    /// When the copy card does NOT exist server-side yet (its create hasn't
    /// flushed), no image is uploaded for that card — the duplicate still
    /// succeeded; the images are simply skipped this pass.
    func testCopyDeckImagesSkipsWhenCopyCardNotYetRemote() async throws {
        let source = Card(id: "src1", deck: "d1", position: 1000, title: "Source")
        let copy = Card(id: "copy1", deck: "d2", position: 1000, title: "Source (copy)")
        let recorder = RecordingImageRepository(imagesByCard: [
            "src1": [CardImage(id: "i1", card: "src1", position: 1000)]
        ])
        let repo = try makeRepo(imageRepo: recorder, cardExists: { _ in false })

        await repo.copyDeckImages(pairs: [(source: source, copy: copy)])

        XCTAssertTrue(recorder.uploads.isEmpty,
                      "a copy card not yet existing server-side must get zero uploads")
    }

    /// Legacy / no-deps path: without the image deps, `copyDeckImages` is a no-op
    /// (cards-only behaviour preserved); the duplicate flow still works.
    func testCopyDeckImagesNoOpWithoutImageDeps() async throws {
        let source = Card(id: "src1", deck: "d1", position: 1000, title: "Source")
        let copy = Card(id: "copy1", deck: "d2", position: 1000, title: "Source (copy)")
        let repo = try makeRepo(imageRepo: nil, cardExists: { _ in true })

        // Must not crash and must do nothing observable.
        await repo.copyDeckImages(pairs: [(source: source, copy: copy)])
    }

    /// End-to-end through `duplicateDeck`: a seeded source deck with one card that
    /// has images is duplicated; the detached copy task drains, finds the copy
    /// card exists (stub true), and uploads each image onto the copy card. Asserts
    /// the cards copied AND the images followed.
    func testDuplicateDeckCopiesImagesOntoCopyCards() async throws {
        let container = try LocalMirrorStore.makeContainer(inMemory: true)
        let store = SwiftDataLocalStore(container: container)
        let outbox = SwiftDataOutbox(container: container)

        // Seed a source deck + one card in the mirror.
        let sourceDeck = Deck(id: "d1", owner: "u1", name: "Wedding")
        await store.upsertDeck(sourceDeck)
        let sourceCard = Card(id: "src1", deck: "d1", position: 1000, title: "First look")
        await store.upsertCard(sourceCard)

        let recorder = RecordingImageRepository(imagesByCard: [
            "src1": [
                CardImage(id: "i1", card: "src1", position: 1000),
                CardImage(id: "i2", card: "src1", position: 2000),
            ]
        ])

        let repo = MirrorDeckRepository(
            store: store,
            outbox: outbox,
            currentUserId: "u1",
            imageRepo: recorder,
            awaitOutboxDrain: { /* no-op: the in-memory mirror already holds the copy card */ },
            cardExistsRemotely: { _ in true }
        )

        let copy = try await repo.duplicateDeck(id: "d1", ownerId: "u1")
        XCTAssertTrue(copy.name.hasSuffix("(copy)"))

        // The copy card is created in the mirror synchronously by duplicateDeck.
        let copyCards = await store.cards(deckId: copy.id).filter { $0.deletedAt == nil }
        XCTAssertEqual(copyCards.count, 1, "the source card must be copied")
        let copyCardId = copyCards[0].id

        // The image copy is DETACHED — poll briefly for it to complete.
        for _ in 0..<50 where recorder.uploads.count < 2 {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(recorder.uploads.count, 2, "both source images must be copied (detached)")
        XCTAssertEqual(Set(recorder.uploads.map(\.cardId)), [copyCardId],
                       "images must attach to the copy card, not the source")
        XCTAssertEqual(recorder.uploads.map(\.position).sorted(), [1000, 2000])
    }
}
