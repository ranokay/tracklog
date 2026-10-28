import Foundation
import Testing
@testable import TracklogCore

@Suite("Service endpoints")
struct ServiceEndpointTests {
    private func normalized(_ text: String) -> String? {
        ServiceEndpoint(normalizing: text)?.description
    }

    @Test func lowercasesTheSchemeAndHostAndDropsATrailingSlash() {
        #expect(normalized(" HTTPS://API.ListenBrainz.ORG/ ") == "https://api.listenbrainz.org")
    }

    @Test func dropsTheHTTPSDefaultPort() {
        #expect(normalized("https://api.listenbrainz.org:443") == "https://api.listenbrainz.org")
    }

    @Test func keepsACustomPort() {
        #expect(normalized("https://example.com:8443/gnufm") == "https://example.com:8443/gnufm")
    }

    @Test func keepsACustomRootPathWithoutItsTrailingSlash() {
        #expect(normalized("https://example.com/gnufm/") == "https://example.com/gnufm")
    }

    @Test func normalizingIsIdempotent() {
        let endpoint = ServiceEndpoint(normalizing: "https://example.com/gnufm/")
        #expect(endpoint.flatMap { ServiceEndpoint(normalizing: $0.description) } == endpoint)
    }

    @Test(arguments: [
        "",
        "   ",
        "libre.fm",
        "http://libre.fm",
        "https://",
        "https://user:secret@example.com",
        "https://example.com?query=1",
        "https://example.com#fragment",
    ])
    func rejectsAnythingButAPlainHTTPSRoot(_ text: String) {
        #expect(ServiceEndpoint(normalizing: text) == nil)
    }

    @Test func serviceKindsHaveTheirFixedNormalizedEndpoints() {
        #expect(ServiceKind.listenBrainz.defaultEndpoint.description == "https://api.listenbrainz.org")
        #expect(ServiceKind.lastFM.defaultEndpoint.description == "https://ws.audioscrobbler.com")
        #expect(ServiceKind.libreFM.defaultEndpoint.description == "https://libre.fm")
    }

    @Test func everyServiceKindDisplayNameIsSettled() {
        #expect(ServiceKind.lastFM.displayName == "Last.fm")
        #expect(ServiceKind.libreFM.displayName == "Libre.fm")
        #expect(ServiceKind.listenBrainz.displayName == "ListenBrainz")
    }

    @Test func serviceKindRawValuesAreStableForPersistence() {
        #expect(ServiceKind.lastFM.rawValue == "lastfm")
        #expect(ServiceKind.libreFM.rawValue == "librefm")
        #expect(ServiceKind.listenBrainz.rawValue == "listenbrainz")
        #expect(ServiceKind(rawValue: "listenbrainz") == .listenBrainz)
    }
}
