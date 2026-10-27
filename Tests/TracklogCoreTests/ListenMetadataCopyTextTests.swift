import Testing
@testable import TracklogCore

@Suite("Listen metadata copy text")
struct ListenMetadataCopyTextTests {
    @Test func copyTextIsArtistTitleAndAlbumWhenPresent() {
        #expect(
            ListenMetadata(title: "Heart of Glass", artist: "Blondie", album: "Parallel Lines")
                .copyText == "Blondie - Heart of Glass (Parallel Lines)",
        )
        #expect(
            ListenMetadata(title: "Heart of Glass", artist: "Blondie")
                .copyText == "Blondie - Heart of Glass",
        )
        #expect(
            ListenMetadata(title: "Heart of Glass", artist: "Blondie", album: "  ")
                .copyText == "Blondie - Heart of Glass",
        )
        #expect(
            ListenMetadata(title: "Heart of Glass", album: "Parallel Lines")
                .copyText == "Heart of Glass (Parallel Lines)",
        )
    }
}
