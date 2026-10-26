import Foundation
import Testing
import TracklogCore

@Suite("Track identity")
struct TrackTests {
    @Test func identityIgnoresCaseAndSurroundingWhitespace() {
        let first = Track(
            title: " Song ",
            artist: " Artist ",
            album: " Album ",
            duration: 200,
            bundleID: " com.apple.Music "
        )
        let second = Track(
            title: "song",
            artist: "artist",
            album: "album",
            duration: 180,
            bundleID: "com.apple.music"
        )

        #expect(first.identity == second.identity)
    }

    @Test func identitySeparatesBundleIdentifiers() {
        let music = Track(title: "Song", artist: "Artist", album: "Album", bundleID: "com.apple.Music")
        let spotify = Track(title: "Song", artist: "Artist", album: "Album", bundleID: "com.spotify.client")

        #expect(music.identity != spotify.identity)
    }

    @Test func blankTitleIsEmpty() {
        #expect(Track(title: "").isEmpty)
        #expect(Track(title: "   \n").isEmpty)
        #expect(Track(title: "Song", artist: "", album: "").isEmpty == false)
    }
}
