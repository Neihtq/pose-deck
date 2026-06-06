import XCTest
import CoreGraphics
@testable import PoseDeckCore

/// Tests for the pure, platform-free parts of ``ImageCompressor``:
/// SHA-256 determinism and the resize math. (The UIKit bitmap path needs a
/// device/simulator and is exercised by the app target.)
final class ImageCompressorTests: XCTestCase {

    func testSHA256IsDeterministic() {
        let data = Data("pose-deck reference image bytes".utf8)
        let a = ImageCompressor.sha256Hex(data)
        let b = ImageCompressor.sha256Hex(data)
        XCTAssertEqual(a, b, "SHA-256 of identical bytes must match")
        XCTAssertEqual(a.count, 64, "SHA-256 hex is 64 lowercase chars")
    }

    func testSHA256KnownVector() {
        // SHA-256("abc") — standard test vector.
        let hex = ImageCompressor.sha256Hex(Data("abc".utf8))
        XCTAssertEqual(
            hex,
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func testSHA256DiffersForDifferentInput() {
        XCTAssertNotEqual(
            ImageCompressor.sha256Hex(Data("a".utf8)),
            ImageCompressor.sha256Hex(Data("b".utf8))
        )
    }

    func testInstanceHashMatchesStatic() {
        let compressor = ImageCompressor()
        let data = Data("x".utf8)
        XCTAssertEqual(compressor.sha256Hex(data), ImageCompressor.sha256Hex(data))
    }

    func testFittedSizeScalesLandscapeToLongEdge() {
        let fitted = ImageCompressor.fittedSize(for: CGSize(width: 4000, height: 3000), maxLongEdge: 1080)
        XCTAssertEqual(fitted.width, 1080, accuracy: 0.5)
        XCTAssertEqual(fitted.height, 810, accuracy: 0.5, "aspect ratio preserved")
    }

    func testFittedSizeScalesPortraitToLongEdge() {
        let fitted = ImageCompressor.fittedSize(for: CGSize(width: 3000, height: 4000), maxLongEdge: 1080)
        XCTAssertEqual(fitted.height, 1080, accuracy: 0.5)
        XCTAssertEqual(fitted.width, 810, accuracy: 0.5)
    }

    func testFittedSizeNeverUpscales() {
        let small = CGSize(width: 800, height: 600)
        let fitted = ImageCompressor.fittedSize(for: small, maxLongEdge: 1080)
        XCTAssertEqual(fitted, small, "images already within the box are unchanged")
    }

    func testFittedSizeExactlyAtBoundIsUnchanged() {
        let fitted = ImageCompressor.fittedSize(for: CGSize(width: 1080, height: 540), maxLongEdge: 1080)
        XCTAssertEqual(fitted, CGSize(width: 1080, height: 540))
    }
}
