import Foundation
import Testing
@testable import TracklogCore

@Suite("Search template")
struct SearchTemplateTests {
    private func template(_ raw: String) throws -> SearchTemplate {
        try SearchTemplate.parse(raw).get()
    }

    private func error(_ raw: String) -> SearchTemplateError? {
        switch SearchTemplate.parse(raw) {
        case .success:
            nil
        case let .failure(error):
            error
        }
    }

    @Test func aTemplateNeedsExactlyOneQueryPlaceholder() {
        #expect(error("https://example.com/search") == .missingPlaceholder)
        #expect(error("https://example.com/{query}/{query}") == .duplicatePlaceholder)
        #expect(error("") == .missingPlaceholder)
        #expect(error("   ") == .missingPlaceholder)
    }

    @Test func onlyHTTPAndHTTPSAddressesAreAllowed() {
        #expect(error("ftp://example.com/{query}") == .schemeNotAllowed)
        #expect(error("file:///tmp/{query}") == .schemeNotAllowed)
        #expect(error("javascript:alert({query})") == .schemeNotAllowed)
        #expect(error("https://example.com/{query}") == nil)
        #expect(error("http://example.com/{query}") == nil)
    }

    @Test func theTemplateNeedsAHostAndNoUserInfo() {
        #expect(error("https:///search?q={query}") == .missingHost)
        #expect(error("https://user@example.com/search?q={query}") == .userInfoNotAllowed)
        #expect(error("https://user:secret@example.com/search?q={query}") == .userInfoNotAllowed)
    }

    @Test func thePlaceholderBelongsToThePathQueryOrFragment() {
        #expect(error("https://{query}.example.com/") == .placeholderInAuthority)
        #expect(error("https://user-{query}@example.com/") == .placeholderInAuthority)
        #expect(error("https://example.com/{query}") == nil)
        #expect(error("https://example.com/search?q={query}") == nil)
        #expect(error("https://example.com/search#q={query}") == nil)
    }

    @Test func aTemplateThatCannotParseIsRejected() {
        #expect(error("https://[::1/{query}") == .invalidTemplate)
    }

    @Test func aQueryIsEncodedWithRFC3986UnreservedCharacters() throws {
        let template = try template("https://example.com/search?q={query}")

        #expect(SearchTemplate.percentEncoded("a b") == "a%20b")
        #expect(SearchTemplate.percentEncoded("a&b") == "a%26b")
        #expect(SearchTemplate.percentEncoded("a/b") == "a%2Fb")
        #expect(SearchTemplate.percentEncoded("a#b") == "a%23b")
        #expect(SearchTemplate.percentEncoded("a?b") == "a%3Fb")
        #expect(SearchTemplate.percentEncoded("a+b") == "a%2Bb")
        #expect(SearchTemplate.percentEncoded("a%b") == "a%25b")
        #expect(SearchTemplate.percentEncoded("é") == "%C3%A9")
        #expect(SearchTemplate.percentEncoded("AZaz09-._~") == "AZaz09-._~")

        let url = try #require(template.url(for: "Heart of Glass"))
        #expect(url.absoluteString == "https://example.com/search?q=Heart%20of%20Glass")
    }

    @Test func substitutionIsOnePassSoTypedPlaceholderTextStaysData() throws {
        let template = try template("https://example.com/search?q={query}")

        let url = try #require(template.url(for: "{query}&x=1"))
        #expect(url.absoluteString == "https://example.com/search?q=%7Bquery%7D%26x%3D1")

        let repeated = try #require(template.url(for: "{query}{query}"))
        #expect(repeated.absoluteString == "https://example.com/search?q=%7Bquery%7D%7Bquery%7D")
    }

    @Test func anEmptyQueryDoesNotRender() throws {
        let template = try template("https://example.com/search?q={query}")

        #expect(template.url(for: "") == nil)
        #expect(template.url(for: "   ") == nil)
    }

    @Test func parsingTrimsTheOuterWhitespaceAndKeepsTheTemplate() throws {
        let template = try template("  https://example.com/search?q={query}\n")

        #expect(template.rawValue == "https://example.com/search?q={query}")
    }

    @Test func aNilParseKeepsThePreviousChoice() {
        #expect(SearchTemplate.parseOrNil("") == nil)
        #expect(SearchTemplate.parseOrNil("nope") == nil)
        #expect(SearchTemplate.parseOrNil("https://example.com/{query}") != nil)
    }
}
