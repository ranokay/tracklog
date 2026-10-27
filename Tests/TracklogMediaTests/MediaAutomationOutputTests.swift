import Foundation
import Testing
import TracklogCore
import TracklogMedia

@Suite("Media automation payload")
struct MediaAutomationOutputTests {
    @Test func decodesAMusicTrack() throws {
        let output = fields(["playing", "Song", "Artist", "Album", "Album Artist", "200", "42"])
        let probe = MediaAutomationOutput.parse(output, for: .music)

        let sample = try #require(playingSample(from: probe))
        #expect(sample.track == Track(
            title: "Song",
            artist: "Artist",
            album: "Album",
            albumArtist: "Album Artist",
            duration: 200,
            bundleID: "com.apple.Music",
        ))
        #expect(sample.elapsed == 42)
        #expect(sample.isPlaying)
    }

    @Test func spotifyMillisecondsBecomeSeconds() throws {
        let output = fields(["playing", "Song", "Artist", "Album", "Album Artist", "200000", "42"])
        let probe = MediaAutomationOutput.parse(output, for: .spotify)

        let sample = try #require(playingSample(from: probe))
        #expect(sample.track.duration == 200)
        #expect(sample.track.bundleID == "com.spotify.client")
    }

    @Test func trailingWhitespaceAndNewlinesAreTrimmed() throws {
        let output = fields(["playing", " Song ", " Artist ", " Album ", " Album Artist ", "200\n", "42\n"])
        let probe = MediaAutomationOutput.parse(output, for: .music)

        let sample = try #require(playingSample(from: probe))
        #expect(sample.track.title == "Song")
        #expect(sample.elapsed == 42)
    }

    @Test func pausedAndStoppedAreNotPlaying() {
        #expect(MediaAutomationOutput.parse("paused", for: .music) == .paused)
        #expect(MediaAutomationOutput.parse("stopped", for: .spotify) == .stopped)
        #expect(MediaAutomationOutput.parse("fast forwarding", for: .music) == .paused)
    }

    @Test func malformedOutputIsAFailure() {
        #expect(MediaAutomationOutput.parse("", for: .music) == .failed("Automation returned no player state"))
        #expect(MediaAutomationOutput.parse("playing", for: .music) == .failed(
            "Automation returned a playing state without a track",
        ))
        #expect(MediaAutomationOutput.parse(fields(["playing", "", "Artist"]), for: .music) == .failed(
            "Automation returned a playing state without a track",
        ))
    }

    private func fields(_ values: [String]) -> String {
        values.joined(separator: MediaAutomationOutput.fieldSeparator)
    }

    private func playingSample(from probe: MediaAutomationProbe) -> MediaSample? {
        guard case let .playing(sample) = probe else { return nil }
        return sample
    }
}
