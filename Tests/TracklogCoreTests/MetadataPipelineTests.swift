import Foundation
import Testing
@testable import TracklogCore

@Suite("Metadata pipeline")
struct MetadataPipelineTests {
    private func track(
        title: String = "Song",
        artist: String = "Artist",
        album: String = "Album",
        albumArtist: String = "Album Artist",
    ) -> Track {
        Track(title: title, artist: artist, album: album, albumArtist: albumArtist)
    }

    private func rule(
        match: SimpleEditRule.Match = .init(),
        replace: SimpleEditRule.Replacement = .init(),
        savedAt: TimeInterval = 0,
    ) -> SimpleEditRule {
        SimpleEditRule(
            match: match,
            replacement: replace,
            savedAt: Date(timeIntervalSince1970: 1_000_000 + savedAt),
        )
    }

    // MARK: - Sentinel cleanup

    @Test func sentinelCleanupRunsBeforeRules() throws {
        let cleanup = rule(
            match: .init(album: "Unknown Album"),
            replace: .init(track: "Rule ran"),
        )

        let processed = try #require(
            MetadataPipeline.process(
                track(album: "Unknown Album"),
                edits: [cleanup],
            ),
        )

        #expect(processed.album.isEmpty)
        #expect(processed.title == "Song", "the rule matched the raw album, not the cleaned one")
    }

    @Test func sentinelCleanupEmptiesTheArtistPlaceholder() {
        #expect(MetadataPipeline.process(track(artist: "va")) == nil)
        #expect(MetadataPipeline.process(track(artist: " VA ")) == nil)
    }

    @Test(
        "Unknown placeholders are emptied",
        arguments: [
            "unknown", "[unknown]", "<unknown>",
            "unknown album", "[unknown album]", "<unknown album>",
            "unknown artist", "[unknown artist]", "<unknown artist>",
            " UNKNOWN ALBUM ",
        ],
    )
    func unknownPlaceholdersAreEmptied(value: String) throws {
        let processed = try #require(
            MetadataPipeline.process(track(album: value, albumArtist: value)),
        )

        #expect(processed.album.isEmpty)
        #expect(processed.albumArtist.isEmpty)
    }

    @Test func albumArtistVAIsTheOneKnownVariousArtistsValue() throws {
        let processed = try #require(
            MetadataPipeline.process(track(albumArtist: " va ")),
        )

        #expect(processed.albumArtist == "Various Artists")
    }

    @Test func titleIsNotSentinelCleaned() throws {
        let processed = try #require(MetadataPipeline.process(track(title: "Unknown")))

        #expect(processed.title == "Unknown")
    }

    // MARK: - Matching

    @Test func matchingIsCaseInsensitiveAndTrimsOnlyWhitespace() throws {
        let edit = rule(
            match: .init(track: "  sOnG ", artist: "ARTIST"),
            replace: .init(album: "Fixed"),
        )

        let processed = try #require(
            MetadataPipeline.process(
                track(title: " Song ", artist: " artist "),
                edits: [edit],
            ),
        )

        #expect(processed.album == "Fixed")
    }

    @Test func internalWhitespaceStillHasToMatchExactly() throws {
        let edit = rule(
            match: .init(track: "A Song"),
            replace: .init(album: "Fixed"),
        )

        let processed = try #require(
            MetadataPipeline.process(track(title: "A  Song"), edits: [edit]),
        )

        #expect(processed.album == "Album")
    }

    @Test func anInactiveMatchFieldIsAWildcard() throws {
        let edit = rule(
            match: .init(album: "Album"),
            replace: .init(artist: "Fixed Artist"),
        )

        let processed = try #require(
            MetadataPipeline.process(
                track(title: "Another Song", artist: "Another Artist"),
                edits: [edit],
            ),
        )

        #expect(processed.artist == "Fixed Artist")
    }

    @Test func everyActiveMatchFieldMustMatch() throws {
        let edit = rule(
            match: .init(track: "Song", artist: "Someone Else"),
            replace: .init(album: "Fixed"),
        )

        let processed = try #require(MetadataPipeline.process(track(), edits: [edit]))

        #expect(processed.album == "Album")
    }

    @Test func anEnabledEmptyMatchFieldMatchesAnEmptyField() throws {
        let edit = rule(
            match: .init(album: ""),
            replace: .init(artist: "Fixed Artist"),
        )

        let emptyAlbum = try #require(
            MetadataPipeline.process(track(album: ""), edits: [edit]),
        )
        let withAlbum = try #require(
            MetadataPipeline.process(track(album: "Album"), edits: [edit]),
        )

        #expect(emptyAlbum.artist == "Fixed Artist")
        #expect(withAlbum.artist == "Artist")
    }

    // MARK: - Merging

    @Test func rulesMergePerFieldBySpecificityThenRecency() throws {
        let broad = rule(
            match: .init(track: "song"),
            replace: .init(artist: "Broad Artist", album: "Broad Album"),
            savedAt: 2,
        )
        let specific = rule(
            match: .init(track: "song", artist: "artist"),
            replace: .init(artist: "Specific Artist"),
            savedAt: 1,
        )
        let newest = rule(
            match: .init(track: "song", artist: "artist"),
            replace: .init(artist: "Newest Artist"),
            savedAt: 3,
        )

        let processed = try #require(
            MetadataPipeline.process(track(), edits: [broad, specific, newest]),
        )

        #expect(processed.artist == "Newest Artist", "same specificity, newest rule first")
        #expect(processed.album == "Broad Album", "a broader rule fills an unclaimed field")
    }

    @Test func theFirstRuleToClaimAFieldWins() throws {
        let specific = rule(
            match: .init(track: "song", artist: "artist"),
            replace: .init(album: "Specific Album"),
            savedAt: 1,
        )
        let broad = rule(
            match: .init(track: "song"),
            replace: .init(album: "Broad Album"),
            savedAt: 2,
        )

        let processed = try #require(
            MetadataPipeline.process(track(), edits: [broad, specific]),
        )

        #expect(processed.album == "Specific Album")
    }

    @Test func everyMatchingRuleRunsWithNoChaining() throws {
        let first = rule(
            match: .init(track: "song", artist: "artist"),
            replace: .init(artist: "Changed Artist"),
            savedAt: 1,
        )
        // The second rule matches the original artist, not the first rule's
        // output. Rule chaining would make this replacement depend on order.
        let second = rule(
            match: .init(artist: "artist"),
            replace: .init(album: "Matched Original"),
            savedAt: 2,
        )

        let processed = try #require(
            MetadataPipeline.process(track(), edits: [first, second]),
        )

        #expect(processed.artist == "Changed Artist")
        #expect(processed.album == "Matched Original")
    }

    // MARK: - Replacements

    @Test func aDisabledReplacementLeavesTheFieldAlone() throws {
        let edit = rule(
            match: .init(track: "song"),
            replace: .init(track: "Fixed Title"),
        )

        let processed = try #require(MetadataPipeline.process(track(), edits: [edit]))

        #expect(processed.title == "Fixed Title")
        #expect(processed.artist == "Artist")
        #expect(processed.album == "Album")
        #expect(processed.albumArtist == "Album Artist")
    }

    @Test func anEmptyReplacementClearsAlbumAndAlbumArtist() throws {
        let edit = rule(
            match: .init(artist: "artist"),
            replace: .init(album: "", albumArtist: ""),
        )

        let processed = try #require(MetadataPipeline.process(track(), edits: [edit]))

        #expect(processed.album.isEmpty)
        #expect(processed.albumArtist.isEmpty)
    }

    @Test func emptyTrackAndArtistReplacementsAreIgnored() throws {
        let edit = rule(
            match: .init(artist: "artist"),
            replace: .init(track: "", artist: "  ", album: "Fixed Album"),
        )

        let processed = try #require(MetadataPipeline.process(track(), edits: [edit]))

        #expect(processed.title == "Song")
        #expect(processed.artist == "Artist")
        #expect(processed.album == "Fixed Album")
    }

    @Test func replacementWhitespaceIsTrimmedByTheFinalTrim() throws {
        let edit = rule(
            match: .init(track: "song"),
            replace: .init(album: "  Fixed Album  "),
        )

        let processed = try #require(MetadataPipeline.process(track(), edits: [edit]))

        #expect(processed.album == "Fixed Album")
    }

    // MARK: - Validity

    @Test func finalTrimKeepsAnEmptyAlbumAndAlbumArtist() throws {
        let processed = try #require(
            MetadataPipeline.process(track(album: "  ", albumArtist: "  ")),
        )

        #expect(processed.album.isEmpty)
        #expect(processed.albumArtist.isEmpty)
    }

    @Test func anEmptyTitleOrArtistAfterThePipelineDropsTheListen() {
        #expect(MetadataPipeline.process(track(title: "  ")) == nil)
        #expect(MetadataPipeline.process(track(artist: "  ")) == nil)
        #expect(MetadataPipeline.process(track(artist: "va")) == nil)
    }
}

@Suite("Simple edit validation")
struct SimpleEditValidationTests {
    private func rule(
        match: SimpleEditRule.Match = .init(),
        replace: SimpleEditRule.Replacement = .init(),
    ) -> SimpleEditRule {
        SimpleEditRule(match: match, replacement: replace)
    }

    @Test func aRuleNeedsAnActiveMatchField() {
        let invalid = rule(replace: .init(album: "Fixed"))

        #expect(invalid.validationError == .noMatchFields)
    }

    @Test func aRuleNeedsAnActiveReplacement() {
        let invalid = rule(match: .init(track: "song"))

        #expect(invalid.validationError == .noReplacements)
    }

    @Test func aRuleCannotClearTheTitle() {
        let invalid = rule(
            match: .init(track: "song"),
            replace: .init(track: "", artist: "Fixed Artist"),
        )

        #expect(invalid.validationError == .cannotClearTrack)
    }

    @Test func aRuleCannotClearTheArtist() {
        let invalid = rule(
            match: .init(artist: "artist"),
            replace: .init(artist: "  "),
        )

        #expect(invalid.validationError == .cannotClearArtist)
    }

    @Test func aValidRulePassesValidation() {
        let valid = rule(
            match: .init(album: ""),
            replace: .init(album: "", albumArtist: "Fixed Album Artist"),
        )

        #expect(valid.validationError == nil)
    }
}
