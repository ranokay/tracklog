import Foundation
import Testing
@testable import TracklogCore

@Suite("Blocks")
@MainActor
struct BlockTests: CaptureTestHelpers {
    @Test func aMatchingBlockCancelsTheListen() {
        let block = BlockRule(track: "Song")

        #expect(MetadataPipeline.process(track(), blocks: [block]) == nil)
    }

    @Test func blankFieldsAreWildcards() throws {
        let block = BlockRule(artist: "Artist")

        let otherSong = try #require(
            MetadataPipeline.process(
                track(title: "Another Song", artist: "Someone Else", album: "Another Album"),
                blocks: [block],
            ),
        )

        #expect(otherSong.title == "Another Song")
    }

    @Test func everyFilledBlockFieldMustMatch() throws {
        let block = BlockRule(track: "Song", artist: "Someone Else")

        let processed = try #require(MetadataPipeline.process(track(), blocks: [block]))

        #expect(processed.title == "Song")
    }

    @Test func matchingIsFullFieldAndCaseInsensitive() {
        let caseInsensitive = BlockRule(track: "  sOnG ", artist: "ARTIST")
        let partial = BlockRule(track: "Son")

        #expect(MetadataPipeline.process(track(), blocks: [caseInsensitive]) == nil)
        #expect(MetadataPipeline.process(track(), blocks: [partial]) != nil)
    }

    @Test func anAllBlankBlockIsRefused() {
        #expect(BlockRule().validationError == .noFields)
        #expect(BlockRule(track: " ", artist: "\n", album: "\t").validationError == .noFields)
        #expect(BlockRule(album: "Album").validationError == nil)
    }

    @Test func anAllBlankRuleIsNeverApplied() throws {
        let processed = try #require(
            MetadataPipeline.process(track(), blocks: [BlockRule()]),
        )

        #expect(processed.title == "Song")
    }

    @Test func blocksRunAfterSentinelCleanup() {
        let beforeCleanup = BlockRule(albumArtist: "VA")
        let afterCleanup = BlockRule(albumArtist: "Various Artists")

        #expect(MetadataPipeline.process(track(albumArtist: "VA"), blocks: [beforeCleanup]) != nil)
        #expect(MetadataPipeline.process(track(albumArtist: "VA"), blocks: [afterCleanup]) == nil)
    }

    @Test func blocksRunBeforeSimpleEdits() {
        let edit = simpleEditRule(
            match: .init(track: "Song"),
            replace: .init(album: "Fixed Album"),
        )
        let block = BlockRule(album: "Album")

        #expect(
            MetadataPipeline.process(track(), edits: [edit], blocks: [block]) == nil,
            "the edit would have rewritten the album the block matches",
        )
    }

    @Test func theMostSpecificBlockIsTheOneReported() throws {
        let broad = BlockRule(artist: "Artist", savedAt: base.addingTimeInterval(3))
        let specific = BlockRule(track: "Song", artist: "Artist", savedAt: base.addingTimeInterval(1))
        let newest = BlockRule(track: "Song", artist: "Artist", savedAt: base.addingTimeInterval(2))

        let matched = try #require(
            BlockRule.firstMatch(in: [broad, specific, newest], for: ListenMetadata(track())),
        )

        #expect(matched == newest)
    }
}
