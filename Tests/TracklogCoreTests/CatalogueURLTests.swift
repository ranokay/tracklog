import Foundation
import Testing
@testable import TracklogCore

@Suite("Catalogue URLs")
struct CatalogueURLTests {
    @Test func schemelessAndHTTPLinksBecomeHTTPS() throws {
        let schemeless = try #require(CatalogueURL.httpsURL(from: "www.last.fm/music/Blondie"))
        #expect(schemeless.absoluteString == "https://www.last.fm/music/Blondie")

        let insecure = try #require(CatalogueURL.httpsURL(from: "http://www.last.fm/music/Blondie"))
        #expect(insecure.absoluteString == "https://www.last.fm/music/Blondie")

        let secure = try #require(CatalogueURL.httpsURL(from: "https://www.last.fm/music/Blondie"))
        #expect(secure.absoluteString == "https://www.last.fm/music/Blondie")
    }

    @Test func otherSchemesHostlessAndUserInfoValuesAreRejected() {
        #expect(CatalogueURL.httpsURL(from: "javascript:alert(1)") == nil)
        #expect(CatalogueURL.httpsURL(from: "ftp://www.last.fm/music/Blondie") == nil)
        #expect(CatalogueURL.httpsURL(from: "https:///no-host") == nil)
        #expect(CatalogueURL.httpsURL(from: "https://user:secret@www.last.fm/music/Blondie") == nil)
        #expect(CatalogueURL.httpsURL(from: "") == nil)
        #expect(CatalogueURL.httpsURL(from: nil) == nil)
    }

    @Test func aValidServiceLinkKeepsItsPathAndQuery() throws {
        let url = try #require(
            CatalogueURL.httpsURL(from: "www.last.fm/music/Blondie/_/Heart+of+Glass?utm_source=api"),
        )
        #expect(url.absoluteString == "https://www.last.fm/music/Blondie/_/Heart+of+Glass?utm_source=api")
    }
}
