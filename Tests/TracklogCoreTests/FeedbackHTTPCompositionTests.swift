import Foundation
import Testing
@testable import TracklogCore

@Suite("Feedback HTTP composition")
@MainActor
struct FeedbackHTTPCompositionTests: CaptureTestHelpers {
    private let base = Date(timeIntervalSince1970: 1_000_000)

    @Test func realListenBrainzAdapterAuthenticatesLookupAndFeedbackWithoutSigningOut() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let credentials = MemoryCredentialStore()
        let clock = FakeClock(base)
        let probe = HUDProbe()
        let transport = ScriptedTransport([
            HTTPResponse(
                statusCode: 200,
                body: Data(#"{"recording_mbid":"mbid-1"}"#.utf8),
            ),
            HTTPResponse(statusCode: 200, body: Data(#"{"status":"ok"}"#.utf8)),
        ])
        let adapter = ListenBrainzAdapter(transport: transport)
        let connection = try await saveHUDConnection(
            store,
            credentials: credentials,
            kind: .listenBrainz,
            base: base,
        )
        let listen = try await insertHistoryListen(store, base: base)
        let runtime = makeHUDRuntime(
            store: store,
            clock: clock,
            probe: probe,
            adapters: [adapter],
            credentials: credentials,
        )
        await runtime.start()

        let love = Task { await runtime.toggleLove(for: listen) }
        _ = await awaitRequests(transport, count: 1)
        clock.advance(to: clock.now.addingTimeInterval(1))
        await love.value

        let requests = await transport.requests
        #expect(requests.count == 2)
        let lookup = try #require(requests.first)
        #expect(lookup.method == .get)
        let lookupComponents = try #require(
            URLComponents(url: lookup.url, resolvingAgainstBaseURL: false),
        )
        #expect(lookupComponents.path == "/1/metadata/lookup/")
        #expect(lookup.headers["Authorization"] == "Token token")
        let feedback = try #require(requests.last)
        #expect(feedback.method == .post)
        #expect(feedback.url.path == "/1/feedback/recording-feedback")
        #expect(feedback.headers["Authorization"] == "Token token")
        let bodyData = try #require(feedback.body)
        let body = try #require(
            JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
        )
        #expect(body["recording_mbid"] as? String == "mbid-1")
        #expect(body["score"] as? Int == 1)
        #expect(runtime.state.connection(id: connection.id ?? -1)?.authState == .signedIn)
        #expect(probe.presentations.last?.spoken == "Loved on ListenBrainz.")
    }
}
