import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import TracklogCore
import UniformTypeIdentifiers

@Suite("Artwork")
struct ArtworkTests {
    private func dimensions(of data: Data) throws -> (width: Int, height: Int) {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return (image.width, image.height)
    }

    @Test func downscalesTheLongEdgeAndHashesTheNormalizedBytes() throws {
        let tall = try #require(testImageData(width: 1024, height: 2048))

        let artwork = try #require(ArtworkNormalizer.normalize(tall))

        #expect(artwork.pixelHeight == 512)
        #expect(artwork.pixelWidth == 256)
        #expect(artwork.hash.count == 64)
        let hexCharacters = Set("0123456789abcdef")
        let isHex = artwork.hash.allSatisfy { hexCharacters.contains($0) }
        #expect(isHex)
        #expect(try dimensions(of: artwork.data) == (256, 512))
    }

    @Test func sameImageNormalizesToTheSameContentHash() throws {
        let data = try #require(testImageData(width: 900, height: 600))

        let first = try #require(ArtworkNormalizer.normalize(data))
        let second = try #require(ArtworkNormalizer.normalize(data))

        #expect(first.hash == second.hash)
        #expect(first.data == second.data)
    }

    @Test func differentImagesHaveDifferentContentHashes() throws {
        let blue = try #require(testImageData(width: 400, height: 400, red: 0.1, green: 0.2, blue: 0.9))
        let red = try #require(testImageData(width: 400, height: 400, red: 0.9, green: 0.2, blue: 0.1))

        let first = try #require(ArtworkNormalizer.normalize(blue))
        let second = try #require(ArtworkNormalizer.normalize(red))

        #expect(first.hash != second.hash)
    }

    @Test func aSmallImageIsNotUpscaled() throws {
        let small = try #require(testImageData(width: 100, height: 80))

        let artwork = try #require(ArtworkNormalizer.normalize(small))

        #expect(artwork.pixelWidth == 100)
        #expect(artwork.pixelHeight == 80)
    }

    @Test func invalidDataHasNoArtwork() {
        #expect(ArtworkNormalizer.normalize(Data()) == nil)
        #expect(ArtworkNormalizer.normalize(Data("not an image".utf8)) == nil)
    }

    @Test func theNeutralSleeveIsStableForATrackIdentity() {
        let style = NeutralSleeve.style(for: "Heart of Glass\u{1F}Blondie\u{1F}Parallel Lines\u{1F}")

        #expect(style == NeutralSleeve.style(for: "  heart of glass \u{1F} BLONDIE\u{1F}Parallel Lines\u{1F} "))
    }

    @Test func theNeutralSleeveIsBoundedAndUsesNoteGlyphs() {
        for index in 0 ..< 50 {
            let style = NeutralSleeve.style(for: "Song \(index)")

            #expect(NeutralSleeve.glyphs.contains(style.glyph))
            #expect(style.fillOpacity >= 0 && style.fillOpacity <= 1)
            #expect(style.glyphOpacity >= 0 && style.glyphOpacity <= 1)
        }
    }

    @Test func differentTracksDoNotAllShareOneNeutralSleeve() {
        let styles = Set((0 ..< 50).map { NeutralSleeve.style(for: "Song \($0)") })

        #expect(styles.count > 1)
    }
}
