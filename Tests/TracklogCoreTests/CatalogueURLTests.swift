import Foundation
import Testing
@testable import TracklogCore

@Suite("Catalogue URLs")
struct CatalogueURLTests {
    @Test func schemelessAndHTTPLinksBecomeHTTPS() throws {
        let schemeless = try #require(CatalogueURL.https("www.last.fm/music/Blondie"))
        #expect(schemeless.absoluteString == "https://www.last.fm/music/Blondie")

        let insecure = try #require(CatalogueURL.https("http://www.last.fm/music/Blondie"))
        #expect(insecure.absoluteString == "https://www.last.fm/music/Blondie")

        let secure = try #require(CatalogueURL.https("https://www.last.fm/music/Blondie"))
        #expect(secure.absoluteString == "https://www.last.fm/music/Blondie")
    }

    @Test func otherSchemesHostlessAndUserInfoValuesAreRejected() {
        #expect(CatalogueURL.https("javascript:alert(1)") == nil)
        #expect(CatalogueURL.https("ftp://www.last.fm/music/Blondie") == nil)
        #expect(CatalogueURL.https("https:///no-host") == nil)
        #expect(CatalogueURL.https("https://user:secret@www.last.fm/music/Blondie") == nil)
        #expect(CatalogueURL.https("") == nil)
        #expect(CatalogueURL.https(nil) == nil)
    }

    @Test func aValidServiceLinkKeepsItsPathAndQuery() throws {
        let url = try #require(
            CatalogueURL.https("www.last.fm/music/Blondie/_/Heart+of+Glass?utm_source=api"),
        )
        #expect(url.absoluteString == "https://www.last.fm/music/Blondie/_/Heart+of+Glass?utm_source=api")
    }
}
