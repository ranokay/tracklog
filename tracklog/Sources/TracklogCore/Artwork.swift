import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One image, normalized for storage and named by its content.
///
/// The long edge is capped so a large cover does not cost a listener more disk
/// than it needs, and the hash is taken over the encoded result rather than the
/// source file: the same cover delivered as PNG and as JPEG still shares one
/// row when the normalized bytes agree.
public struct StoredArtwork: Equatable, Sendable {
    public let hash: String
    public let data: Data
    public let pixelWidth: Int
    public let pixelHeight: Int

    public init(hash: String, data: Data, pixelWidth: Int, pixelHeight: Int) {
        self.hash = hash
        self.data = data
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

/// Turns the media helper's embedded image bytes into the one form the store
/// keeps.
public enum ArtworkNormalizer {
    /// The largest sleeve is 64 points. 512 pixels covers it on a 2x display
    /// with room for the History row's 52-point sleeve.
    public static let maximumLongEdge = 512

    public static func normalize(_ data: Data) -> StoredArtwork? {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0
        else {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumLongEdge,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let encoded = encode(image)
        else {
            return nil
        }

        let digest = SHA256.hash(data: encoded)
        let hash = digest.map { String(format: "%02x", $0) }.joined()
        return StoredArtwork(
            hash: hash,
            data: encoded,
            pixelWidth: image.width,
            pixelHeight: image.height,
        )
    }

    /// JPEG keeps a photographic cover small. An image that cannot be written
    /// as JPEG, such as one with an unusual colour space, falls back to PNG
    /// rather than dropping the artwork.
    private static func encode(_ image: CGImage) -> Data? {
        if let jpeg = encode(image, as: .jpeg, options: [
            kCGImageDestinationLossyCompressionQuality: 0.8,
        ]) {
            return jpeg
        }
        return encode(image, as: .png, options: [:])
    }

    private static func encode(
        _ image: CGImage,
        as type: UTType,
        options: [CFString: Any],
    ) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            type.identifier as CFString,
            1,
            nil,
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

/// The sleeve a track gets when no artwork can be shown.
///
/// It is deliberately neutral: a card fill and a note glyph whose choice and
/// weight come from the track's identity, so the same missing cover looks the
/// same everywhere and two tracks do not look accidentally identical.
public struct NeutralSleeve: Hashable, Sendable {
    /// Note-family SF Symbols used by the sleeve.
    public static let glyphs = ["music.note", "music.quarternote.3", "music.note.list"]

    public let glyph: String
    public let fillOpacity: Double
    public let glyphOpacity: Double

    public init(glyph: String, fillOpacity: Double, glyphOpacity: Double) {
        self.glyph = glyph
        self.fillOpacity = fillOpacity
        self.glyphOpacity = glyphOpacity
    }

    public static func style(for identity: String) -> NeutralSleeve {
        let seed = stableHash(canonical(identity))
        let glyph = glyphs[Int(seed % UInt64(glyphs.count))]
        let fills = [0.0, 0.03, 0.06]
        let opacities = [0.35, 0.45, 0.55]
        return NeutralSleeve(
            glyph: glyph,
            fillOpacity: fills[Int((seed >> 8) % UInt64(fills.count))],
            glyphOpacity: opacities[Int((seed >> 16) % UInt64(opacities.count))],
        )
    }

    /// Identity components carry the player's spacing; a sleeve should not
    /// change because one poll reported an extra space around the artist.
    private static func canonical(_ identity: String) -> String {
        Identity.joined(
            identity
                .split(separator: "\u{1F}", omittingEmptySubsequences: false)
                .map(String.init),
        )
    }

    /// FNV-1a is enough here: the result picks a glyph and two small opacity
    /// steps, not a security boundary, and it is stable across launches.
    private static func stableHash(_ value: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }
}
