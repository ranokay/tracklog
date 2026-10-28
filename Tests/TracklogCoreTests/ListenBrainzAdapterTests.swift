import Foundation
import Testing
@testable import TracklogCore

@Suite("ListenBrainz linking")
struct ListenBrainzAdapterTests {
    private func response(
        _ status: Int,
        _ json: String,
        headers: [String: String] = [:],
    ) -> HTTPResponse {
        HTTPResponse(statusCode: status, headers: headers, body: Data(json.utf8))
    }

    private func adapter(_ transport: any HTTPTransport) -> ListenBrainzAdapter {
        ListenBrainzAdapter(transport: transport)
    }

    @Test func validatesATokenAndReadsTheIdentity() async throws {
        let transport = ScriptedTransport([
            listenBrainzValidResponse(),
        ])

        let identity = try await adapter(transport).validate(" abc123\n")

        #expect(identity.name == "listener")
        #expect(identity.displayName == "listener")
        let request = try #require(await transport.requests.first)
        #expect(request.method == .get)
        #expect(request.url.absoluteString == "https://api.listenbrainz.org/1/validate-token")
        #expect(request.headers["Authorization"] == "Token abc123")
        #expect(request.headers["Accept"] == "application/json")
        #expect(request.headers["User-Agent"] == TracklogHTTP.userAgent)
        #expect(TracklogHTTP.userAgent.hasPrefix("Tracklog/"))
        #expect(TracklogHTTP.userAgent.contains("https://"))
    }

    @Test func anEmptyTokenNeverReachesTheNetwork() async throws {
        let transport = ScriptedTransport([response(200, "{}")])

        await #expect(throws: ServiceFailure.rejected("Enter a user token.")) {
            _ = try await adapter(transport).validate("   ")
        }

        #expect(await transport.requests.isEmpty)
    }

    @Test func aRejectedTokenMapsToAuth() async throws {
        let transport = ScriptedTransport([
            response(401, #"{"code":401,"message":"Invalid token"}"#),
        ])

        await #expect(throws: ServiceFailure.auth) {
            _ = try await adapter(transport).validate("bad")
        }
    }

    @Test func aTwoHundredWithValidFalseMapsToAuth() async throws {
        let transport = ScriptedTransport([
            response(200, #"{"code":200,"valid":false,"message":"Invalid token"}"#),
        ])

        await #expect(throws: ServiceFailure.auth) {
            _ = try await adapter(transport).validate("bad")
        }
    }

    @Test func rateLimitingCarriesTheServerHint() async throws {
        let transport = ScriptedTransport([
            response(
                429,
                #"{"code":429,"message":"Rate limit exceeded"}"#,
                headers: ["X-RateLimit-Reset-In": "30"],
            ),
        ])

        await #expect(throws: ServiceFailure.rateLimited(retryAfter: 30)) {
            _ = try await adapter(transport).validate("token")
        }
    }

    @Test func aServerFailureIsRetryable() async throws {
        let transport = ScriptedTransport([response(503, "")])

        await #expect(throws: ServiceFailure.retryable) {
            _ = try await adapter(transport).validate("token")
        }
    }

    @Test func aBadRequestCarriesTheServerMessage() async throws {
        let transport = ScriptedTransport([
            response(400, #"{"code":400,"message":"Missing token"}"#),
        ])

        await #expect(throws: ServiceFailure.rejected("Missing token")) {
            _ = try await adapter(transport).validate("token")
        }
    }

    @Test func aMalformedSuccessBodyIsRetryable() async throws {
        let transport = ScriptedTransport([response(200, "not json")])

        await #expect(throws: ServiceFailure.retryable) {
            _ = try await adapter(transport).validate("token")
        }
    }

    @Test func aTransportFailureIsRetryable() async throws {
        let transport = ScriptedTransport(error: .notConnectedToInternet)

        await #expect(throws: ServiceFailure.retryable) {
            _ = try await adapter(transport).validate("token")
        }
    }

    @Test func listenBrainzCapabilitiesMatchTheMilestone() {
        let transport = ScriptedTransport([response(200, "")])
        let capabilities = adapter(transport).capabilities

        #expect(capabilities.supportsNowPlaying)
        #expect(capabilities.maximumBatchSize == 1)
        #expect(capabilities.supportsLove)
        #expect(capabilities.supportsHate)
        #expect(!capabilities.supportsDelete)
        #expect(!capabilities.signsRequests)
    }
}
