import XCTest
import CoreGraphics
#if canImport(ImageIO)
import ImageIO
import UniformTypeIdentifiers
#endif
@testable import PoseDeckCore

/// Regression tests for `ImageCompressor.canDecode(_:)` — the decode-validation
/// predicate that gates the image blob cache so neither the read-path writeback
/// nor the precache writer can poison the SwiftData mirror with empty, truncated,
/// or garbage bytes (iOS gauntlet: "poisoned-cache silent failure", findings
/// #2/#3/#4). Pinned in PoseDeckCore because the app-target writers
/// (`SwiftDataLocalStore.cacheImageBlob`, `PrecacheService.setBlob`) and
/// `ProtectedAsyncImage` aren't reachable from `swift test`; this predicate is
/// the canonical, testable gate they all call.
final class ImageDecodeValidationTests: XCTestCase {

    /// Build a real, fully-valid PNG via ImageIO (works on the macOS test host).
    /// Returns `nil` only if ImageIO is unavailable, in which case the decode
    /// tests below are skipped.
    private func makeValidPNG(width: Int = 8, height: Int = 8) -> Data? {
        #if canImport(ImageIO)
        let bytesPerPixel = 4
        let bitmap = [UInt8](repeating: 0xAA, count: width * height * bytesPerPixel)
        guard let provider = CGDataProvider(data: Data(bitmap) as CFData),
              let cgImage = CGImage(
                width: width, height: height, bitsPerComponent: 8,
                bitsPerPixel: 8 * bytesPerPixel, bytesPerRow: width * bytesPerPixel,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false,
                intent: .defaultIntent
              )
        else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            out as CFMutableData, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
        #else
        return nil
        #endif
    }

    func testValidImageDecodes() throws {
        guard let png = makeValidPNG() else {
            throw XCTSkip("ImageIO unavailable on this host")
        }
        XCTAssertTrue(ImageCompressor.canDecode(png), "a complete PNG must decode")
    }

    func testEmptyDataDoesNotDecode() {
        XCTAssertFalse(ImageCompressor.canDecode(Data()), "empty bytes are not an image")
    }

    func testTruncatedImageDoesNotDecode() throws {
        guard let png = makeValidPNG(width: 64, height: 64) else {
            throw XCTSkip("ImageIO unavailable on this host")
        }
        // A mid-stream truncation: keep enough for the header but drop the pixel
        // data. This is the exact "partial network stream" / poisoned-cache case.
        let truncated = png.prefix(png.count / 3)
        XCTAssertFalse(
            ImageCompressor.canDecode(Data(truncated)),
            "a truncated image stream must be rejected, not cached as valid"
        )
    }

    func testGarbageBytesDoNotDecode() {
        let garbage = Data((0..<512).map { UInt8(($0 * 37 + 11) & 0xFF) })
        XCTAssertFalse(ImageCompressor.canDecode(garbage), "non-image bytes are not an image")
    }

    func testTextMasqueradingAsImageDoesNotDecode() {
        XCTAssertFalse(
            ImageCompressor.canDecode(Data("not an image, just a 404 body".utf8)),
            "a non-image HTTP body (e.g. an error page) must not be treated as cacheable image bytes"
        )
    }
}
