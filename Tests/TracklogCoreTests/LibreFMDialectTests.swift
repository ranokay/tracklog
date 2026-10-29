import Foundation
import Testing
@testable import TracklogCore

@Suite("Libre.fm / GNU FM")
@MainActor
struct LibreFMDialectTests {
    private let clientKey = "0123456789abcdef0123456789abcdef"

    private func adapter(_ responses: [HTTPResponse]) -> (LibreFMAdapter, ScriptedTransport) {
        let transport = ScriptedTransport(responses)
        return (LibreFMAdapter(transport: transport, clientKey: clientKey), transport)
    }

    private func connection(_ root: String = "https://gnufm.example") throws -> Connection {
        try Connection(
            kind: .libreFM,
            endpoint: #require(ServiceEndpoint(normalizing: root)),
            identity: "listener",
            createdAt: Date(timeIntervalSince1970: 1_000_000),
        )
    }

    // MARK: - Link

    @Test func requestsATokenAtTheConfiguredRootWithoutASignature() async throws {
        let (adapter, transport) = adapter([lastFMTokenResponse()])
        let endpoint = try #require(ServiceEndpoint(normalizing: "https://gnufm.example/"))

        let challenge = try await adapter.linkClient(for: endpoint).requestToken()

        #expect(challenge.token == "request-token")
        let authorization = try #require(
            URLComponents(url: challenge.authorizationURL, resolvingAgainstBaseURL: false),
        )
        #expect(authorization.scheme == "https")
        #expect(authorization.host == "gnufm.example")
        #expect(authorization.path == "/api/auth/")
        #expect(authorization.queryItems?.first { $0.name == "api_key" }?.value == clientKey)
        #expect(authorization.queryItems?.first { $0.name == "token" }?.value == "request-token")

        let request = try #require(await transport.requests.first)
        #expect(request.method == .post)
        #expect(request.url.absoluteString == "https://gnufm.example/2.0/")
        #expect(request.headers["User-Agent"] == TracklogHTTP.userAgent)
        let params = formParameters(request)
        #expect(params["method"] == "auth.getToken")
        #expect(params["api_key"] == clientKey)
        #expect(params["format"] == "json")
        #expect(params["sk"] == nil)
        #expect(params["api_sig"] == nil)
    }

    @Test func keepsACustomRootPathInTheApiAndAuthorizationPages() async throws {
        let (adapter, transport) = adapter([lastFMTokenResponse()])
        let endpoint = try #require(ServiceEndpoint(normalizing: "https://example.com/gnufm"))

        let challenge = try await adapter.linkClient(for: endpoint).requestToken()

        let authorization = try #require(
            URLComponents(url: challenge.authorizationURL, resolvingAgainstBaseURL: false),
        )
        #expect(authorization.path == "/gnufm/api/auth/")
        let request = try #require(await transport.requests.first)
        #expect(request.url.absoluteString == "https://example.com/gnufm/2.0/")
    }

    @Test func exchangesTheTokenForASessionWithoutASignature() async throws {
        let (adapter, _) = adapter([lastFMSessionResponse()])
        let endpoint = try #require(ServiceEndpoint(normalizing: "https://gnufm.example"))

        let session = try await adapter.linkClient(for: endpoint).session(token: " request-token\n")

        #expect(session == LastFMSession(name: "listener", key: "session-key"))
    }

    // MARK: - Delivery

    @Test func sendsOneScrobblePerPost() async throws {
        let (adapter, transport) = adapter([lastFMScrobbleResponse(codes: [0])])

        let results = try await adapter.submit(
            [lastFMTestListen()],
            connection: connection(),
            credential: "session-key",
        )

        #expect(results == [.delivered(reference: nil)])
        let request = try #require(await transport.requests.first)
        #expect(request.url.absoluteString == "https://gnufm.example/2.0/")
        let params = formParameters(request)
        #expect(params["method"] == "track.scrobble")
        #expect(params["artist[0]"] == "Artist 0")
        #expect(params["track[0]"] == "Track 0")
        #expect(params["timestamp[0]"] == "1000000")
        #expect(params["sk"] == "session-key")
        #expect(params["api_key"] == clientKey)
        #expect(params["api_sig"] == nil)
    }

    @Test func refusesASecondScrobbleWithoutSending() async throws {
        let (adapter, transport) = adapter([])

        await #expect(throws: ServiceFailure.rejected("Libre.fm accepts one scrobble per request.")) {
            _ = try await adapter.submit(
                [lastFMTestListen(index: 0), lastFMTestListen(index: 1)],
                connection: connection(),
                credential: "session-key",
            )
        }
        #expect(await transport.requests.isEmpty)
    }

    @Test func deliversToTheRootTheConnectionWasLinkedWith() async throws {
        let (adapter, transport) = adapter([lastFMScrobbleResponse(codes: [0])])

        _ = try await adapter.submit(
            [lastFMTestListen()],
            connection: connection("https://music.example.org"),
            credential: "session-key",
        )

        let request = try #require(await transport.requests.first)
        #expect(request.url.absoluteString == "https://music.example.org/2.0/")
    }

    @Test func mapsAnIgnoredScrobbleToARejection() async throws {
        let (adapter, _) = adapter([lastFMScrobbleResponse(codes: [1])])

        let results = try await adapter.submit(
            [lastFMTestListen()],
            connection: connection(),
            credential: "session-key",
        )

        #expect(results == [.rejected(reason: "Libre.fm ignored this scrobble (code 1).")])
    }

    @Test func mapsTheDailyLimitToARateLimit() async throws {
        let (adapter, _) = adapter([lastFMScrobbleResponse(codes: [5])])

        let results = try await adapter.submit(
            [lastFMTestListen()],
            connection: connection(),
            credential: "session-key",
        )

        #expect(results == [.rateLimited(retryAfter: nil)])
    }

    @Test func sendsNowPlayingWithoutASignature() async throws {
        let (adapter, transport) = adapter([lastFMEmptyResponse()])

        try await adapter.submitNowPlaying(
            lastFMTestTrack(),
            connection: connection(),
            credential: "session-key",
        )

        let request = try #require(await transport.requests.first)
        let params = formParameters(request)
        #expect(params["method"] == "track.updateNowPlaying")
        #expect(params["artist"] == "Blondie")
        #expect(params["sk"] == "session-key")
        #expect(params["api_sig"] == nil)
    }

    @Test func loveAndUnloveAreUnsignedCalls() async throws {
        let (adapter, transport) = adapter([lastFMEmptyResponse(), lastFMEmptyResponse()])
        let connection = try connection()

        try await adapter.love(lastFMTestTrack(), connection: connection, credential: "session-key")
        try await adapter.unlove(lastFMTestTrack(), connection: connection, credential: "session-key")

        let requests = await transport.requests
        #expect(requests.count == 2)
        let love = try formParameters(#require(requests.first))
        #expect(love["method"] == "track.love")
        #expect(love["artist"] == "Blondie")
        #expect(love["track"] == "Heart of Glass")
        #expect(love["sk"] == "session-key")
        #expect(love["api_sig"] == nil)
        let unlove = formParameters(requests[1])
        #expect(unlove["method"] == "track.unlove")
        #expect(unlove["api_sig"] == nil)
    }

    // MARK: - Identity and failures

    @Test func readsTheIdentityFromTheLinkedRoot() async throws {
        let (adapter, transport) = adapter([lastFMUserResponse(name: "listener")])
        let endpoint = try #require(ServiceEndpoint(normalizing: "https://gnufm.example"))

        let identity = try await adapter.validate("session-key", endpoint: endpoint)

        #expect(identity == ServiceIdentity(name: "listener"))
        let request = try #require(await transport.requests.first)
        #expect(request.url.absoluteString == "https://gnufm.example/2.0/")
        #expect(formParameters(request)["api_sig"] == nil)
    }

    @Test func aRejectedSessionMapsToAuthAndATransportFailureToRetryable() async throws {
        let (rejected, _) = adapter([lastFMErrorResponse(code: 9)])
        await #expect(throws: ServiceFailure.auth) {
            _ = try await rejected.submit(
                [lastFMTestListen()],
                connection: connection(),
                credential: "session-key",
            )
        }

        let transport = ScriptedTransport(error: .notConnectedToInternet)
        let offline = LibreFMAdapter(transport: transport, clientKey: clientKey)
        await #expect(throws: ServiceFailure.retryable) {
            _ = try await offline.submit(
                [lastFMTestListen()],
                connection: connection(),
                credential: "session-key",
            )
        }
    }

    @Test func anUnregisteredClientKeyIsNamedOnTheLinkPage() async throws {
        let (adapter, _) = adapter([lastFMErrorResponse(code: 10, message: "Invalid API key")])
        let endpoint = try #require(ServiceEndpoint(normalizing: "https://gnufm.example"))

        await #expect(throws: ServiceFailure.rejected(LibreFMAdapter.clientKeyRejectionMessage)) {
            _ = try await adapter.linkClient(for: endpoint).requestToken()
        }
    }

    @Test func anUnapprovedTokenStaysAPollableLastFMError() async throws {
        let (adapter, _) = adapter([lastFMErrorResponse(code: 14)])
        let endpoint = try #require(ServiceEndpoint(normalizing: "https://gnufm.example"))

        await #expect(throws: LastFMError.service(code: 14, message: "The service rejected the request.")) {
            _ = try await adapter.linkClient(for: endpoint).session(token: "request-token")
        }
    }

    @Test func aRejectedClientKeyHoldsDeliveriesInsteadOfAbandoningThem() async throws {
        let (adapter, _) = adapter([lastFMErrorResponse(code: 10)])

        await #expect(throws: ServiceFailure.auth) {
            _ = try await adapter.submit(
                [lastFMTestListen()],
                connection: connection(),
                credential: "session-key",
            )
        }
    }

    // MARK: - Capabilities

    @Test func capabilitiesMatchGNUFM() {
        let adapter = LibreFMAdapter(transport: ScriptedTransport([]), clientKey: clientKey)
        let capabilities = adapter.capabilities
        #expect(adapter.kind == .libreFM)
        #expect(capabilities.supportsNowPlaying)
        #expect(capabilities.maximumBatchSize == 1)
        #expect(capabilities.supportsLove)
        #expect(!capabilities.supportsHate)
        #expect(!capabilities.signsRequests)
        #expect(capabilities.minimumRequestInterval == 1)
    }
}
