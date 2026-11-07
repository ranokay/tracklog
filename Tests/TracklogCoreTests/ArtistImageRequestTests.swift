import Foundation
import Testing
@testable import TracklogCore

@Suite("Artist image request")
struct ArtistImageRequestTests {
    private func search(_ artworkURL: String) async throws -> ArtistImageAlbum {
        let transport = EntityTransport { _ in
            HTTPResponse(
                statusCode: 200,
                body: Data(
                    #"""
                    {"resultCount":1,"results":[{"artistId":1012882,"artistName":"Blondie","artworkUrl100":"\#(artworkURL)"}]}
                    """#.utf8,
                ),
            )
        }
        let albums = try await ITunesSearchClient(transport: transport)
            .albums(forArtist: "Blondie", limit: 10)
        return try #require(albums.first)
    }

    @Test func aThumbnailURLIsRequestedAtTheArtistPageSize() async throws {
        let album = try await search("https://is1-ssl.mzstatic.com/image/thumb/Music/abc/100x100bb.jpg")

        #expect(album.artworkURL?.absoluteString == "https://is1-ssl.mzstatic.com/image/thumb/Music/abc/600x600bb.jpg")
    }

    @Test func aURLWithoutAThumbnailSizePassesThroughUnchanged() async throws {
        let album = try await search("https://images.example/artist.jpg")

        #expect(album.artworkURL?.absoluteString == "https://images.example/artist.jpg")
    }
}
