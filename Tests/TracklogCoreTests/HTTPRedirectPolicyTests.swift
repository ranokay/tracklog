import Foundation
import Testing
@testable import TracklogCore

@Suite("Redirect policy")
struct HTTPRedirectPolicyTests {
    @Test(arguments: [
        "https://libre.fm/2.0/",
        "HTTPS://LIBRE.FM/2.0/",
        "https://libre.fm:8443/2.0/",
    ])
    func allowsAnHTTPSDestination(_ url: String) throws {
        #expect(try HTTPRedirectPolicy.allows(#require(URL(string: url))))
    }

    @Test(arguments: [
        "http://libre.fm/2.0/",
        "HTTP://libre.fm/2.0/",
        "ftp://libre.fm/2.0/",
    ])
    func refusesAnythingButHTTPS(_ url: String) throws {
        #expect(try !HTTPRedirectPolicy.allows(#require(URL(string: url))))
    }

    @Test func refusesADestinationWithoutAScheme() throws {
        #expect(try !HTTPRedirectPolicy.allows(#require(URL(string: "/2.0/"))))
    }
}
