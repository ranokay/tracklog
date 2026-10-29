import Foundation
import Testing
@testable import TracklogCore

@Suite("ListenBrainz feedback")
struct ListenBrainzFeedbackTests {
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

    private func track(
        title: String = "Heart of Glass",
        artist: String = "Blondie",
        album: String = "Parallel Lines",
    ) -> Track {
        Track(title: title, artist: artist, album: album)
    }

    private func json(_ request: HTTPRequest) throws -> [String: Any] {
        let body = try #require(request.body)
        return try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    @Test func loveWithAnMSIDPostsTheRecordingFeedbackScore() async throws {
        let transport = ScriptedTransport([response(200, #"{"status":"ok"}"#)])

        try await adapter(transport).submitFeedback(
            .love,
            track: track(),
            reference: .msid("msid-1"),
            connection: connection,
            credential: " token \n",
        )

        let request = try #require(await transport.requests.first)
        #expect(request.method == .post)
        #expect(
            request.url.absoluteString
                == "\(ServiceEndpoint.listenBrainz)/1/feedback/recording-feedback",
        )
        #expect(request.headers["Authorization"] == "Token token")
        #expect(request.headers["Content-Type"] == "application/json")
        #expect(request.headers["User-Agent"] == TracklogHTTP.userAgent)
        let body = try json(request)
        #expect(body["recording_msid"] as? String == "msid-1")
        #expect(body["recording_mbid"] == nil)
        #expect(body["score"] as? Int == 1)
    }

    @Test func hateWithAnMBIDUsesMinusOne() async throws {
        let transport = ScriptedTransport([response(200, #"{"status":"ok"}"#)])

        try await adapter(transport).submitFeedback(
            .hate,
            track: track(),
            reference: .mbid("mbid-1"),
            connection: connection,
            credential: "token",
        )

        let body = try json(#require(await transport.requests.first))
        #expect(body["recording_mbid"] as? String == "mbid-1")
        #expect(body["recording_msid"] == nil)
        #expect(body["score"] as? Int == -1)
    }

    @Test func unloveResetsTheScore() async throws {
        let transport = ScriptedTransport([response(200, #"{"status":"ok"}"#)])

        try await adapter(transport).submitFeedback(
            .unlove,
            track: track(),
            reference: .msid("msid-1"),
            connection: connection,
            credential: "token",
        )

        let body = try json(#require(await transport.requests.first))
        #expect(body["score"] as? Int == 0)
    }

    @Test func missingReferenceResolvesThroughMetadataLookup() async throws {
        let transport = ScriptedTransport([
            response(
                200,
                #"{"recording_mbid":"mbid-1","recording_name":"Heart of Glass","artist_name":"Blondie"}"#,
            ),
        ])

        let reference = try await adapter(transport).resolveReference(
            for: track(),
            connection: connection,
            credential: " token \n",
        )

        #expect(reference == .mbid("mbid-1"))
        let request = try #require(await transport.requests.first)
        #expect(request.method == .get)
        let components = try #require(URLComponents(url: request.url, resolvingAgainstBaseURL: false))
        #expect(components.path == "/1/metadata/lookup/")
        let query = try #require(components.queryItems)
        #expect(query.first(where: { $0.name == "artist_name" })?.value == "Blondie")
        #expect(query.first(where: { $0.name == "recording_name" })?.value == "Heart of Glass")
        #expect(query.first(where: { $0.name == "release_name" })?.value == "Parallel Lines")
        #expect(request.headers["Authorization"] == "Token token")
        #expect(request.headers["User-Agent"] == TracklogHTTP.userAgent)
    }

    @Test func aLookupWithoutAMatchIsRejected() async throws {
        let transport = ScriptedTransport([
            response(200, #"{"recording_name":"Heart of Glass","artist_name":"Blondie"}"#),
        ])

        await #expect(throws: ServiceFailure.rejected("ListenBrainz could not match that recording.")) {
            _ = try await adapter(transport).resolveReference(
                for: track(),
                connection: connection,
                credential: "token",
            )
        }
    }

    @Test func feedbackErrorsUseTheDeliveryTaxonomy() async throws {
        let unauthorized = ScriptedTransport([response(401, #"{"error":"Invalid token"}"#)])
        await #expect(throws: ServiceFailure.auth) {
            try await adapter(unauthorized).submitFeedback(
                .love,
                track: track(),
                reference: .msid("msid-1"),
                connection: connection,
                credential: "bad",
            )
        }

        let limited = ScriptedTransport([
            response(429, #"{"error":"Rate limit exceeded"}"#, headers: ["X-RateLimit-Reset-In": "45"]),
        ])
        await #expect(throws: ServiceFailure.rateLimited(retryAfter: 45)) {
            try await adapter(limited).submitFeedback(
                .love,
                track: track(),
                reference: .msid("msid-1"),
                connection: connection,
                credential: "token",
            )
        }

        let badRequest = ScriptedTransport([response(400, #"{"error":"Invalid JSON"}"#)])
        await #expect(throws: ServiceFailure.rejected("Invalid JSON")) {
            try await adapter(badRequest).submitFeedback(
                .love,
                track: track(),
                reference: .msid("msid-1"),
                connection: connection,
                credential: "token",
            )
        }

        let server = ScriptedTransport([response(503, "")])
        await #expect(throws: ServiceFailure.retryable) {
            try await adapter(server).submitFeedback(
                .love,
                track: track(),
                reference: .msid("msid-1"),
                connection: connection,
                credential: "token",
            )
        }

        let offline = ScriptedTransport(error: .notConnectedToInternet)
        await #expect(throws: ServiceFailure.retryable) {
            try await adapter(offline).submitFeedback(
                .love,
                track: track(),
                reference: .msid("msid-1"),
                connection: connection,
                credential: "token",
            )
        }
    }

    @Test func aFeedbackWithoutAReferenceIsRejectedBeforeTheNetwork() async throws {
        let transport = ScriptedTransport([])

        await #expect(throws: ServiceFailure.rejected("ListenBrainz needs a recording reference.")) {
            try await adapter(transport).submitFeedback(
                .love,
                track: track(),
                reference: nil,
                connection: connection,
                credential: "token",
            )
        }
        #expect(await transport.requests.isEmpty)
    }

    @Test func listenBrainzDeclaresThatFeedbackNeedsAReference() {
        #expect(adapter(ScriptedTransport([])).requiresReference)
    }
}
