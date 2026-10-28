import Foundation
import Testing
@testable import TracklogCore

@Suite("Last.fm signature")
struct LastFMSignatureTests {
    @Test func matchesTheDocumentedVector() {
        let signature = LastFMSignature.signature(
            parameters: [
                "api_key": "xxxxxxxxxx",
                "method": "auth.getSession",
                "token": "yyyyyy",
                "format": "json",
            ],
            sharedSecret: "ilovecher",
        )

        #expect(signature == "b87d61da3cda91a8b6746c4aef55d6f8")
    }

    @Test func excludesFormatAndCallback() {
        let signed = [
            "api_key": "xxxxxxxxxx",
            "method": "auth.getSession",
            "token": "yyyyyy",
        ]
        let plain = LastFMSignature.signature(parameters: signed, sharedSecret: "ilovecher")
        let withFormat = LastFMSignature.signature(
            parameters: signed.merging(["format": "json", "callback": "tracklog"]) { _, new in new },
            sharedSecret: "ilovecher",
        )

        #expect(plain == withFormat)
    }

    @Test func sortsIndexedParametersInAsciiOrder() {
        let signature = LastFMSignature.signature(
            parameters: [
                "artist[1]": "One",
                "artist[10]": "Ten",
                "artist[0]": "Zero",
            ],
            sharedSecret: "secret",
        )

        #expect(signature == "3e8989aaaa08c0598775f3f50b42d3b5")
    }
}
