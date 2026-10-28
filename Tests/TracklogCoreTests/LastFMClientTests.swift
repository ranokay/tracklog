import Foundation
import Testing
@testable import TracklogCore

@Suite("Last.fm client")
@MainActor
struct LastFMClientTests {
    private let secret = "ilovecher"

    private func adapter(_ responses: [HTTPResponse]) -> (LastFMAdapter, ScriptedTransport) {
        let transport = ScriptedTransport(responses)
        return (LastFMAdapter(transport: transport, appCredentials: lastFMTestCredentials), transport)
    }

    @Test func requestsATokenWithTheDesktopFlow() async throws {
        let (adapter, transport) = adapter([lastFMTokenResponse()])

        let challenge = try await adapter.requestToken()

        #expect(challenge.token == "request-token")
        let query = try #require(URLComponents(url: challenge.authorizationURL, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(URLComponents(url: challenge.authorizationURL, resolvingAgainstBaseURL: false)?.host == "www.last.fm")
        // The documented Last.fm endpoints are the expected values here.
        #expect(URLComponents(url: challenge.authorizationURL, resolvingAgainstBaseURL: false)?.path == "/api/auth/")
        #expect(query.first(where: { $0.name == "api_key" })?.value == "xxxxxxxxxx")
        #expect(query.first(where: { $0.name == "token" })?.value == "request-token")

        let request = try #require(await transport.requests.first)
        #expect(request.method == .post)
        #expect(request.url.absoluteString == "https://ws.audioscrobbler.com/2.0/")
        #expect(request.headers["User-Agent"] == TracklogHTTP.userAgent)
        #expect(request.headers["Content-Type"]?.hasPrefix("application/x-www-form-urlencoded") == true)
        let params = formParameters(request)
        #expect(params["method"] == "auth.getToken")
        #expect(params["api_key"] == "xxxxxxxxxx")
        #expect(params["format"] == "json")
        #expect(params["sk"] == nil)
        #expect(params["api_sig"] == signedParameters(params, secret: secret))
    }

    @Test func exchangesTheTokenForASession() async throws {
        let (adapter, transport) = adapter([lastFMSessionResponse()])

        let session = try await adapter.session(token: "request-token")

        #expect(session == LastFMSession(name: "listener", key: "session-key"))
        let request = try #require(await transport.requests.first)
        let params = formParameters(request)
        #expect(params["method"] == "auth.getSession")
        #expect(params["token"] == "request-token")
        #expect(params["api_key"] == "xxxxxxxxxx")
        #expect(params["api_sig"] == signedParameters(params, secret: secret))
    }

    @Test func validatesASessionKeyThroughUserInfo() async throws {
        let (adapter, transport) = adapter([lastFMUserResponse(name: "listener")])

        let identity = try await adapter.validate("session-key")

        #expect(identity == ServiceIdentity(name: "listener"))
        let request = try #require(await transport.requests.first)
        let params = formParameters(request)
        #expect(params["method"] == "user.getInfo")
        #expect(params["sk"] == "session-key")
        #expect(params["api_key"] == "xxxxxxxxxx")
        #expect(params["api_sig"] == signedParameters(params, secret: secret))
    }

    @Test func sendsNowPlayingAsAScalarFormPost() async throws {
        let (adapter, transport) = adapter([lastFMEmptyResponse()])

        try await adapter.submitNowPlaying(
            lastFMTestTrack(),
            connection: lastFMTestConnection(),
            credential: "session-key",
        )

        let request = try #require(await transport.requests.first)
        let params = formParameters(request)
        #expect(params["method"] == "track.updateNowPlaying")
        #expect(params["artist"] == "Blondie")
        #expect(params["track"] == "Heart of Glass")
        #expect(params["album"] == "Parallel Lines")
        #expect(params["albumArtist"] == "Blondie")
        #expect(params["duration"] == "225")
        #expect(params["sk"] == "session-key")
        #expect(params["artist[0]"] == nil)
        #expect(params["api_sig"] == signedParameters(params, secret: secret))
    }

    @Test func submitsFiftyIndexedScrobblesInOnePost() async throws {
        let listens = (0 ..< 50).map { lastFMTestListen(index: $0) }
        let (adapter, transport) = adapter([lastFMScrobbleResponse(codes: Array(repeating: 0, count: 50))])

        let results = try await adapter.submit(
            listens,
            connection: lastFMTestConnection(),
            credential: "session-key",
        )

        #expect(results == Array(repeating: .delivered(reference: nil), count: 50))
        let requests = await transport.requests
        #expect(requests.count == 1)
        let params = try formParameters(#require(requests.first))
        #expect(params["method"] == "track.scrobble")
        #expect(params["artist[0]"] == "Artist 0")
        #expect(params["track[0]"] == "Track 0")
        #expect(params["timestamp[0]"] == "1000000")
        #expect(params["artist[49]"] == "Artist 49")
        #expect(params["track[49]"] == "Track 49")
        #expect(params["timestamp[49]"] == "1000049")
        #expect(params["sk"] == "session-key")
        #expect(params["api_sig"] == signedParameters(params, secret: secret))
    }

    @Test func includesOnlyPresentOptionalScrobbleFields() async throws {
        let listen = lastFMTestListen(
            album: "  ",
            albumArtist: "Various Artists",
            duration: 0,
        )
        let (adapter, transport) = adapter([lastFMScrobbleResponse(codes: [0])])

        _ = try await adapter.submit([listen], connection: lastFMTestConnection(), credential: "session-key")

        let params = try formParameters(#require(await transport.requests.first))
        #expect(params["album[0]"] == nil)
        #expect(params["albumArtist[0]"] == "Various Artists")
        #expect(params["duration[0]"] == nil)
    }

    @Test func loveAndUnloveAreScalarPosts() async throws {
        let (adapter, transport) = adapter([lastFMEmptyResponse(), lastFMEmptyResponse()])

        try await adapter.love(lastFMTestTrack(), sessionKey: "session-key")
        try await adapter.unlove(lastFMTestTrack(), sessionKey: "session-key")

        let requests = await transport.requests
        let love = try formParameters(#require(requests.first))
        let unlove = try formParameters(#require(requests.last))
        #expect(love["method"] == "track.love")
        #expect(love["artist"] == "Blondie")
        #expect(love["track"] == "Heart of Glass")
        #expect(love["sk"] == "session-key")
        #expect(love["artist[0]"] == nil)
        #expect(unlove["method"] == "track.unlove")
        #expect(unlove["api_sig"] == signedParameters(unlove, secret: secret))
    }

    @Test func refusesMoreThanFiftyScrobblesWithoutSending() async throws {
        let (adapter, transport) = adapter([])
        let listens = (0 ..< 51).map { lastFMTestListen(index: $0) }

        await #expect(throws: ServiceFailure.rejected("Last.fm accepts up to 50 scrobbles per request.")) {
            _ = try await adapter.submit(listens, connection: lastFMTestConnection(), credential: "session-key")
        }
        #expect(await transport.requests.isEmpty)
    }

    @Test func missingAppCredentialsFailBeforeTheNetwork() async throws {
        let transport = ScriptedTransport([])
        let client = LastFMClient(
            transport: transport,
            appCredentials: LastFMAppCredentials(apiKey: "", sharedSecret: ""),
        )

        await #expect(throws: LastFMError.missingAppCredentials) {
            _ = try await client.requestToken()
        }
        #expect(await transport.requests.isEmpty)
        #expect(
            LastFMError.missingAppCredentials.serviceFailure
                == .appCredentialAuth(.missing),
        )
    }

    @Test func anErrorNeverEchoesTheSessionKeyOrSecret() async throws {
        let sessionKey = "session-key-that-must-not-leak"
        let (adapter, _) = adapter([lastFMErrorResponse(code: 9)])
        do {
            _ = try await adapter.submit(
                [lastFMTestListen()],
                connection: lastFMTestConnection(),
                credential: sessionKey,
            )
            Issue.record("expected an auth failure")
        } catch let failure as ServiceFailure {
            #expect(!failure.localizedDescription.contains(sessionKey))
            #expect(!failure.localizedDescription.contains(lastFMTestCredentials.sharedSecret))
        }
    }
}
