import Foundation
import Testing
@testable import TracklogCore

@Suite("ListenBrainz delivery")
struct ListenBrainzDeliveryTests {
    private let base = Date(timeIntervalSince1970: 1_000_000)
    private let connection = Connection(
        kind: .listenBrainz,
        endpoint: .listenBrainz,
        identity: "listener",
        createdAt: Date(timeIntervalSince1970: 1_000_000),
    )

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

    private func listen(
        title: String = "Song",
        start: TimeInterval = 10.6,
    ) -> Listen {
        Listen(
            raw: ListenMetadata(title: title, artist: "Artist", album: "Album"),
            processed: ListenMetadata(title: title, artist: "Artist", album: "Album"),
            bundleID: "com.apple.Music",
            duration: 200,
            playedDuration: 100,
            startedAt: base.addingTimeInterval(start),
            capturedAt: base.addingTimeInterval(start + 100),
        )
    }

    private func json(_ request: HTTPRequest) throws -> [String: Any] {
        let body = try #require(request.body)
        return try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    @Test func submitsASingleListenWithTheReconstructedStart() async throws {
        let transport = ScriptedTransport([response(200, #"{"status":"ok"}"#)])
        let listen = listen()

        let results = try await adapter(transport).submit(
            [listen],
            connection: connection,
            credential: " token \n",
        )

        #expect(results == [.delivered(reference: nil)])
        let request = try #require(await transport.requests.first)
        #expect(request.method == .post)
        #expect(request.url.absoluteString == "https://api.listenbrainz.org/1/submit-listens")
        #expect(request.headers["Authorization"] == "Token token")
        #expect(request.headers["Content-Type"] == "application/json")
        #expect(request.headers["User-Agent"] == TracklogHTTP.userAgent)

        let body = try json(request)
        #expect(body["listen_type"] as? String == "single")
        let payload = try #require(body["payload"] as? [[String: Any]])
        let item = try #require(payload.first)
        #expect(item["listened_at"] as? Int == 1_000_011)
        let metadata = try #require(item["track_metadata"] as? [String: Any])
        #expect(metadata["artist_name"] as? String == "Artist")
        #expect(metadata["track_name"] as? String == "Song")
        #expect(metadata["release_name"] as? String == "Album")
        let additional = try #require(metadata["additional_info"] as? [String: Any])
        #expect(additional["duration_ms"] as? Int == 200_000)
        #expect(additional["duration_played"] as? Int == 100)
        #expect(additional["submission_client"] as? String == "Tracklog")
        #expect(additional["submission_client_version"] as? String == TracklogHTTP.version)
    }

    @Test func submitsPlayingNowWithReturnMsidAndNoStart() async throws {
        let transport = ScriptedTransport([
            response(200, #"{"status":"ok","recording_msid":"msid-1"}"#),
        ])
        let track = Track(
            title: "Song",
            artist: "Artist",
            album: "Album",
            albumArtist: "Album Artist",
            duration: 200,
            bundleID: "com.apple.Music",
        )

        let reference = try await adapter(transport).submitNowPlaying(
            track,
            connection: connection,
            credential: "token",
        )

        #expect(reference == "msid-1")
        let request = try #require(await transport.requests.first)
        #expect(request.url.absoluteString == "https://api.listenbrainz.org/1/submit-listens?return_msid=true")
        let body = try json(request)
        #expect(body["listen_type"] as? String == "playing_now")
        let payload = try #require(body["payload"] as? [[String: Any]])
        let item = try #require(payload.first)
        #expect(item["listened_at"] == nil)
        let metadata = try #require(item["track_metadata"] as? [String: Any])
        #expect(metadata["track_name"] as? String == "Song")
        #expect(metadata["artist_name"] as? String == "Artist")
        #expect(metadata["release_name"] as? String == "Album")
    }

    @Test func aTwoHundredWithoutAnOKStatusIsRetryable() async throws {
        let transport = ScriptedTransport([response(200, #"{"status":"paused"}"#)])

        await #expect(throws: ServiceFailure.retryable) {
            _ = try await adapter(transport).submit([listen()], connection: connection, credential: "token")
        }
    }

    @Test func aMalformedSuccessBodyIsRetryable() async throws {
        let transport = ScriptedTransport([response(200, "not json")])

        await #expect(throws: ServiceFailure.retryable) {
            _ = try await adapter(transport).submit([listen()], connection: connection, credential: "token")
        }
    }

    @Test func aRejectedCredentialMapsToAuth() async throws {
        let transport = ScriptedTransport([
            response(401, #"{"code":401,"error":"Invalid token"}"#),
        ])

        await #expect(throws: ServiceFailure.auth) {
            _ = try await adapter(transport).submit([listen()], connection: connection, credential: "bad")
        }
    }

    @Test func rateLimitingCarriesTheResetHint() async throws {
        let transport = ScriptedTransport([
            response(
                429,
                #"{"code":429,"error":"Rate limit exceeded"}"#,
                headers: ["X-RateLimit-Reset-In": "45"],
            ),
        ])

        await #expect(throws: ServiceFailure.rateLimited(retryAfter: 45)) {
            _ = try await adapter(transport).submit([listen()], connection: connection, credential: "token")
        }
    }

    @Test func aBadRequestKeepsTheServerMessage() async throws {
        let transport = ScriptedTransport([
            response(400, #"{"code":400,"error":"Invalid JSON"}"#),
        ])

        await #expect(throws: ServiceFailure.rejected("Invalid JSON")) {
            _ = try await adapter(transport).submit([listen()], connection: connection, credential: "token")
        }
    }

    @Test func aServerFailureIsRetryable() async throws {
        let transport = ScriptedTransport([response(503, "")])

        await #expect(throws: ServiceFailure.retryable) {
            _ = try await adapter(transport).submit([listen()], connection: connection, credential: "token")
        }
    }

    @Test func aTransportFailureIsRetryable() async throws {
        let transport = ScriptedTransport(error: .notConnectedToInternet)

        await #expect(throws: ServiceFailure.retryable) {
            _ = try await adapter(transport).submit([listen()], connection: connection, credential: "token")
        }
    }

    @Test func listenBrainzDeclaresOneListenAndOneSecondBetweenRequests() {
        let capabilities = adapter(ScriptedTransport([response(200, "{}")])).capabilities

        #expect(capabilities.maximumBatchSize == 1)
        #expect(capabilities.minimumRequestInterval == 1)
        #expect(capabilities.supportsNowPlaying)
    }
}
