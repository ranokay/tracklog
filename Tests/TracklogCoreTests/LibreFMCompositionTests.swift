import Foundation
import Testing
@testable import TracklogCore

@Suite("Libre.fm composition")
@MainActor
struct LibreFMCompositionTests {
    private let base = Date(timeIntervalSince1970: 1_000_000)
    private let clientKey = "0123456789abcdef0123456789abcdef"

    private struct Harness {
        let database: TemporaryDatabase
        let store: SQLiteListenStore
        let state: TracklogAppState
        let runtime: CaptureRuntime
    }

    private func makeHarness(transport: any HTTPTransport) async throws -> Harness {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let state = TracklogAppState()
        let runtime = CaptureRuntime(
            state: state,
            clock: FakeClock(base),
            source: ReplayedNowPlaying(),
            store: store,
            allowlist: InMemoryAppAllowlist(),
            credentials: MemoryCredentialStore(),
            serviceAdapters: [LibreFMAdapter(transport: transport, clientKey: clientKey)],
            settings: CaptureSettings(scrobblingEnabled: false),
        )
        await runtime.start()
        return Harness(database: database, store: store, state: state, runtime: runtime)
    }

    @Test func aLinkOnACustomRootDeliversThere() async throws {
        let transport = ScriptedTransport([lastFMScrobbleResponse(codes: [0])])
        let harness = try await makeHarness(transport: transport)
        let root = try #require(ServiceEndpoint(normalizing: "https://music.example.org"))
        let connection = try await harness.runtime.linkVerified(
            kind: .libreFM,
            credential: "session-key",
            identity: ServiceIdentity(name: "listener"),
            endpoint: root,
        )
        let listen = try #require(
            try await harness.store.insert(lastFMTestListen(), targets: [connection.id ?? -1]),
        )

        harness.runtime.deliveryOutbox?.drain(connectionIDs: [connection.id ?? -1])

        let deliveries = await awaitDeliveries(harness.store, listen: listen) {
            $0.allSatisfy { $0.state == .delivered }
        }
        #expect(deliveries.map(\.state) == [.delivered])
        let requests = await awaitRequests(transport, count: 1)
        let request = try #require(requests.first)
        #expect(request.url.absoluteString == "https://music.example.org/2.0/")
        let params = formParameters(request)
        #expect(params["method"] == "track.scrobble")
        #expect(params["api_key"] == clientKey)
        #expect(params["sk"] == "session-key")
        #expect(params["api_sig"] == nil)
    }

    @Test func aRefusedClientKeyHoldsTheQueueAndMarksTheConnection() async throws {
        let transport = ScriptedTransport([lastFMErrorResponse(code: 10)])
        let harness = try await makeHarness(transport: transport)
        let root = try #require(ServiceEndpoint(normalizing: "https://music.example.org"))
        let connection = try await harness.runtime.linkVerified(
            kind: .libreFM,
            credential: "session-key",
            identity: ServiceIdentity(name: "listener"),
            endpoint: root,
        )
        let listen = try #require(
            try await harness.store.insert(lastFMTestListen(), targets: [connection.id ?? -1]),
        )

        harness.runtime.deliveryOutbox?.drain(connectionIDs: [connection.id ?? -1])

        let deliveries = await awaitDeliveries(harness.store, listen: listen) {
            $0.allSatisfy { $0.state == .retrying }
        }
        #expect(deliveries.map(\.state) == [.retrying], "a refused key never abandons a listen")
        await turnMainActor()
        #expect(harness.state.connection(id: connection.id ?? -1)?.authState == .needsSignIn)
    }

    @Test func nowPlayingReachesTheCustomRoot() async throws {
        let transport = ScriptedTransport([lastFMEmptyResponse()])
        let harness = try await makeHarness(transport: transport)
        let root = try #require(ServiceEndpoint(normalizing: "https://music.example.org"))
        _ = try await harness.runtime.linkVerified(
            kind: .libreFM,
            credential: "session-key",
            identity: ServiceIdentity(name: "listener"),
            endpoint: root,
        )

        harness.runtime.deliveryOutbox?.sendNowPlaying(lastFMTestTrack())

        let requests = await awaitRequests(transport, count: 1)
        let request = try #require(requests.first)
        #expect(request.url.absoluteString == "https://music.example.org/2.0/")
        #expect(formParameters(request)["api_sig"] == nil)
    }
}
