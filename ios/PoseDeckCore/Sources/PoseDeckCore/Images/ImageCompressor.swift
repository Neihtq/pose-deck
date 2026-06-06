import Foundation
import CryptoKit
#if canImport(UIKit)
import UIKit
import ImageIO
import UniformTypeIdentifiers
#endif

/// Errors surfaced by ``ImageCompressor``.
public enum ImageCompressorError: Error, Sendable, Equatable {
    /// The input bytes could not be decoded as an image.
    case decodeFailed
    /// The image could not be re-encoded as JPEG.
    case encodeFailed
    /// Compression is unavailable on this platform (no UIKit/ImageIO).
    case unsupportedPlatform
}

/// Compresses picked images per ARCHITECTURE.md §5: resize to a 1080px long edge
/// and re-encode as JPEG quality 0.8. Also provides a content hash for
/// dedup-on-upload.
///
/// The pixel-math (``fittedSize``) and ``sha256Hex`` are pure and platform-free
/// so they are unit-testable on macOS / Linux. The bitmap path is guarded behind
/// `#if canImport(UIKit)` (iOS only).
public struct ImageCompressor: Sendable {
    /// Default long-edge target in pixels (ARCHITECTURE.md §5).
    public static let defaultMaxLongEdge: CGFloat = 1080
    /// Default JPEG quality (ARCHITECTURE.md §5).
    public static let defaultQuality: CGFloat = 0.8

    public init() {}

    // MARK: - Pure helpers (testable everywhere)

    /// Compute the size that fits `original` within a `maxLongEdge`-pixel box,
    /// preserving aspect ratio. Never upscales: images already within the box are
    /// returned unchanged.
    ///
    /// - Parameters:
    ///   - original: source pixel dimensions.
    ///   - maxLongEdge: the maximum length of the longer edge.
    /// - Returns: the scaled-to-fit size (rounded to whole pixels).
    public static func fittedSize(for original: CGSize, maxLongEdge: CGFloat) -> CGSize {
        let longest = max(original.width, original.height)
        guard longest > maxLongEdge, longest > 0, maxLongEdge > 0 else {
            return original
        }
        let scale = maxLongEdge / longest
        return CGSize(
            width: (original.width * scale).rounded(),
            height: (original.height * scale).rounded()
        )
    }

    /// Lowercase hex SHA-256 of arbitrary bytes — used for dedup-on-upload
    /// (ARCHITECTURE.md §5 step 3). Deterministic and platform-free (CryptoKit).
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Instance convenience for ``sha256Hex(_:)``.
    public func sha256Hex(_ data: Data) -> String {
        Self.sha256Hex(data)
    }

    // MARK: - Compression

    #if canImport(UIKit)
    /// Resize `data` to fit `maxLongEdge` (no upscaling) and re-encode as JPEG at
    /// `quality`. Uses ImageIO's thumbnail path so we don't fully decode large
    /// originals into memory.
    ///
    /// - Returns: the compressed JPEG bytes.
    public func compress(
        _ data: Data,
        maxLongEdge: CGFloat = ImageCompressor.defaultMaxLongEdge,
        quality: CGFloat = ImageCompressor.defaultQuality
    ) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw ImageCompressorError.decodeFailed
        }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            // Honour EXIF orientation so portrait photos aren't sideways.
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxLongEdge),
        ]
        guard
            let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary)
        else {
            throw ImageCompressorError.decodeFailed
        }

        let uiImage = UIImage(cgImage: cgImage)
        guard let jpeg = uiImage.jpegData(compressionQuality: quality) else {
            throw ImageCompressorError.encodeFailed
        }
        return jpeg
    }
    #else
    /// Compression is unavailable without UIKit/ImageIO (e.g. macOS test host).
    /// The pure helpers (``fittedSize(for:maxLongEdge:)``, ``sha256Hex(_:)``)
    /// remain available for unit testing.
    public func compress(
        _ data: Data,
        maxLongEdge: CGFloat = ImageCompressor.defaultMaxLongEdge,
        quality: CGFloat = ImageCompressor.defaultQuality
    ) throws -> Data {
        throw ImageCompressorError.unsupportedPlatform
    }
    #endif
}
