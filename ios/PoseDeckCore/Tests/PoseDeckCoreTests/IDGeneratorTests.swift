import XCTest
@testable import PoseDeckCore

/// Coverage for ``IDGenerator`` (M3 plan, STEP 8 / invariant #1): client-minted
/// ids are 15 chars from PocketBase's alphabet and effectively unique.
final class IDGeneratorTests: XCTestCase {

    func testIdIsFifteenCharsFromAlphabet() {
        let id = IDGenerator.newClientId()
        XCTAssertEqual(id.count, 15)
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789")
        XCTAssertTrue(id.allSatisfy { allowed.contains($0) }, "id uses only the PB alphabet")
    }

    func testIdsAreDistinct() {
        var seen = Set<String>()
        for _ in 0..<1000 { seen.insert(IDGenerator.newClientId()) }
        XCTAssertEqual(seen.count, 1000, "1000 minted ids should not collide")
    }

    func testDeterministicWithSeededRNG() {
        var rng1 = SeededRNG(seed: 42)
        var rng2 = SeededRNG(seed: 42)
        XCTAssertEqual(
            IDGenerator.newClientId(using: &rng1),
            IDGenerator.newClientId(using: &rng2),
            "same seed → same id (deterministic test seam)"
        )
    }
}

/// Tiny deterministic RNG (SplitMix64) for reproducible id tests.
struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
