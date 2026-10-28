import Foundation
import Testing
import TracklogCore
import TracklogMedia

@Suite("Media helper payload")
struct MediaHelperPayloadTests {
    private func data(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    @Test func decodesTheFullPayload() throws {
        let payload = try data([
            "payload": [
                "title": "Song",
                "artist": "Artist",
                "album": "Album",
                "albumArtist": "Album Artist",
                "duration": 200.0,
                "elapsedTime": 42.0,
                "playbackRate": 1.0,
                "playing": true,
                "parentApplicationBundleIdentifier": "com.apple.Music",
            ],
        ])

        let sample = MediaHelperPayload.decode(payload)

        #expect(sample?.track == Track(
            title: "Song",
            artist: "Artist",
            album: "Album",
            albumArtist: "Album Artist",
            duration: 200,
            bundleID: "com.apple.Music",
        ))
        #expect(sample?.elapsed == 42)
        #expect(sample?.playbackRate == 1)
        #expect(sample?.isPlaying == true)
        #expect(abs((sample?.timestamp.timeIntervalSinceNow ?? 0)) < 1)
    }

    @Test func playingFallsBackToPlaybackRate() throws {
        let playing = try data(["payload": ["title": "Song", "playbackRate": 1.0]])
        let paused = try data(["payload": ["title": "Song", "playbackRate": 0.0]])

        #expect(MediaHelperPayload.decode(playing)?.isPlaying == true)
        #expect(MediaHelperPayload.decode(paused)?.isPlaying == false)
    }

    @Test func explicitPlayingWinsOverRate() throws {
        let payload = try data(["payload": ["title": "Song", "playbackRate": 1.0, "playing": false]])

        #expect(MediaHelperPayload.decode(payload)?.isPlaying == false)
    }

    @Test func bundleIdentifierFallsBackToThePlainKey() throws {
        let payload = try data(["payload": [
            "title": "Song",
            "bundleIdentifier": "com.spotify.client",
        ]])

        #expect(MediaHelperPayload.decode(payload)?.track.bundleID == "com.spotify.client")
    }

    @Test func parentBundleIdentifierWins() throws {
        let payload = try data(["payload": [
            "title": "Song",
            "bundleIdentifier": "com.spotify.client",
            "parentApplicationBundleIdentifier": "com.apple.Music",
        ]])

        #expect(MediaHelperPayload.decode(payload)?.track.bundleID == "com.apple.Music")
    }

    @Test func missingOptionalFieldsUseEmptyDefaults() throws {
        let payload = try data(["payload": ["title": "Song"]])

        let sample = MediaHelperPayload.decode(payload)

        #expect(sample?.track.artist == "")
        #expect(sample?.track.album == "")
        #expect(sample?.track.albumArtist == "")
        #expect(sample?.track.duration == 0)
        #expect(sample?.track.bundleID == "")
        #expect(sample?.elapsed == 0)
        #expect(sample?.playbackRate == 0)
        #expect(sample?.isPlaying == false)
    }

    @Test func integerNumbersDecode() {
        let payload = Data(#"{"payload":{"title":"Song","duration":200,"elapsedTime":42,"playbackRate":1}}"#.utf8)

        let sample = MediaHelperPayload.decode(payload)

        #expect(sample?.track.duration == 200)
        #expect(sample?.elapsed == 42)
        #expect(sample?.playbackRate == 1)
    }

    @Test func usesTheHelperReportedTimestamp() {
        let fractional = Data(#"{"payload":{"title":"Song","timestamp":"1970-01-12T13:46:40.789Z"}}"#.utf8)
        let whole = Data(#"{"payload":{"title":"Song","timestamp":"1970-01-12T13:46:40Z"}}"#.utf8)

        #expect(MediaHelperPayload.decode(fractional)?.timestamp == Date(timeIntervalSince1970: 1_000_000.789))
        #expect(MediaHelperPayload.decode(whole)?.timestamp == Date(timeIntervalSince1970: 1_000_000))
    }

    @Test func malformedTimestampFallsBackToNow() {
        let payload = Data(#"{"payload":{"title":"Song","timestamp":"not a date"}}"#.utf8)

        let timestamp = MediaHelperPayload.decode(payload)?.timestamp ?? .distantPast

        #expect(abs(timestamp.timeIntervalSinceNow) < 1)
    }

    @Test func missingOrBlankTitleIsNil() throws {
        let missing = try data(["payload": ["artist": "Artist"]])
        let blank = try data(["payload": ["title": "   "]])

        #expect(MediaHelperPayload.decode(missing) == nil)
        #expect(MediaHelperPayload.decode(blank) == nil)
    }

    @Test func malformedDataIsNil() {
        #expect(MediaHelperPayload.decode(Data("not json".utf8)) == nil)
        #expect(MediaHelperPayload.decode(Data()) == nil)
    }

    @Test func missingPayloadObjectIsNil() throws {
        let payload = try data(["title": "Song"])

        #expect(MediaHelperPayload.decode(payload) == nil)
    }

    @Test func decodesTheEmbeddedArtworkBytes() throws {
        let bytes = Data([1, 2, 3, 4])
        let payload = try data(["payload": [
            "title": "Song",
            "artworkMIMEType": "image/jpeg",
            "artworkData": bytes.base64EncodedString(),
        ]])

        let snapshot = try #require(MediaHelperPayload.decodeSnapshot(payload))

        #expect(snapshot.artwork == bytes)
        #expect(snapshot.sample.track.title == "Song")
    }

    @Test func anArtworkURLWithoutEmbeddedBytesIsNotArtwork() throws {
        // The helper's artworkIdentifier is a remote URL. Tracklog deliberately
        // never opens it: only the bytes embedded in the same payload count.
        var components = URLComponents()
        components.scheme = "https"
        components.host = "example.com"
        components.path = "/" + "cover.jpg"
        let artworkIdentifier = try #require(components.string)
        let payload = try data(["payload": [
            "title": "Song",
            "artworkIdentifier": artworkIdentifier,
            "artworkMIMEType": "image/jpeg",
        ]])

        let snapshot = try #require(MediaHelperPayload.decodeSnapshot(payload))

        #expect(snapshot.artwork == nil)
        #expect(MediaHelperPayload.decode(payload)?.track.title == "Song")
    }

    @Test func invalidEmbeddedArtworkIsNotArtwork() throws {
        let payload = try data(["payload": [
            "title": "Song",
            "artworkData": "not base64 !!!",
        ]])

        #expect(MediaHelperPayload.decodeSnapshot(payload)?.artwork == nil)
    }

    @Test func noArtworkReadsAsASampleWithoutArtwork() throws {
        let payload = try data(["payload": ["title": "Song"]])

        let snapshot = try #require(MediaHelperPayload.decodeSnapshot(payload))

        #expect(snapshot.artwork == nil)
        #expect(snapshot.sample.track.title == "Song")
    }
}

@Suite("Media helper reader")
@MainActor
struct MediaHelperReaderTests {
    @Test func missingHelperReportsTheMissingExecutable() async {
        let reader = MediaHelperReader(bundleURL: URL(fileURLWithPath: "/nonexistent"))

        #expect(reader.isExecutable == false)
        #expect(await reader.read() == .missingExecutable)
        #expect(await reader.readArtwork() == .unavailable)
    }
}
