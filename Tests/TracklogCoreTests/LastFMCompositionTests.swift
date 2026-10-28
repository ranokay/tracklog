import Foundation
import Testing
@testable import TracklogCore

@Suite("Last.fm composition")
@MainActor
struct LastFMCompositionTests {
    private let base = Date(timeIntervalSince1970: 1_000_000)

    private struct Harness {
        let database: TemporaryDatabase
        let store: SQLiteListenStore
        let credentials: MemoryCredentialStore
        let clock: FakeClock
        let state: TracklogAppState
        let runtime: CaptureRuntime
    }

    private func makeHarness(
        transport: any HTTPTransport,
        connectionLog: @escaping @MainActor (ConnectionEvent) -> Void = { _ in },
        deliveryLog: @escaping @MainActor (DeliveryEvent) -> Void = { _ in },
    ) async throws -> Harness {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let credentials = MemoryCredentialStore()
        let clock = FakeClock(base)
        let state = TracklogAppState()
        let adapter = LastFMAdapter(
            transport: transport,
            appCredentials: lastFMTestCredentials,
        )
        let runtime = CaptureRuntime(
            state: state,
            clock: clock,
            source: ReplayedNowPlaying(),
            store: store,
            allowlist: InMemoryAppAllowlist(),
            credentials: credentials,
            serviceAdapters: [adapter],
            connectionLog: connectionLog,
            deliveryLog: deliveryLog,
            settings: CaptureSettings(scrobblingEnabled: false),
        )
        await runtime.start()
        return Harness(
            database: database,
            store: store,
            credentials: credentials,
            clock: clock,
            state: state,
            runtime: runtime,
        )
    }

    private func linked(
        _ harness: Harness,
        credential: String = "session-key",
    ) async throws -> Connection {
        try await harness.runtime.linkVerified(
            kind: .lastFM,
            credential: credential,
            identity: ServiceIdentity(name: "listener"),
        )
    }

    @Test func aVerifiedLinkStoresTheSessionKeyAndPublishesTheConnection() async throws {
        let harness = try await makeHarness(transport: ScriptedTransport([]))

        let connection = try await linked(harness)

        #expect(connection.kind == .lastFM)
        #expect(connection.identity == "listener")
        #expect(connection.isEnabled)
        #expect(connection.authState == .signedIn)
        #expect(harness.state.connections == [connection])
        #expect(harness.state.currentConnectionID == connection.id)
        #expect(
            try await harness.credentials.credential(forConnection: connection.id ?? -1) == "session-key",
        )
    }

    @Test func aLinkedConnectionNowPlaysThroughTheOutbox() async throws {
        let transport = ScriptedTransport([lastFMEmptyResponse()])
        let harness = try await makeHarness(transport: transport)
        _ = try await linked(harness)

        harness.runtime.deliveryOutbox?.sendNowPlaying(lastFMTestTrack())

        let requests = await awaitRequests(transport, count: 1)
        let params = try formParameters(#require(requests.first))
        #expect(params["method"] == "track.updateNowPlaying")
        #expect(params["sk"] == "session-key")
        #expect(params["track"] == "Heart of Glass")
        #expect(params["artist"] == "Blondie")
    }

    @Test func aQueuedListenDeliversToLastFMThroughTheOutbox() async throws {
        let transport = ScriptedTransport([lastFMScrobbleResponse(codes: [0])])
        let harness = try await makeHarness(transport: transport)
        let connection = try await linked(harness)
        let listen = try #require(
            try await harness.store.insert(
                lastFMTestListen(),
                targets: [connection.id ?? -1],
            ),
        )

        harness.runtime.deliveryOutbox?.drain(connectionIDs: [connection.id ?? -1])

        let deliveries = await awaitDeliveries(harness.store, listen: listen) {
            $0.allSatisfy { $0.state == .delivered }
        }
        #expect(deliveries.map(\.state) == [.delivered])

        let requests = await awaitRequests(transport, count: 1)
        let params = try formParameters(#require(requests.first))
        #expect(params["method"] == "track.scrobble")
        #expect(params["sk"] == "session-key")
        #expect(params["artist[0]"] == "Artist 0")
        #expect(params["track[0]"] == "Track 0")
        #expect(params["timestamp[0]"] == "1000000")
    }

    @Test func anUnparseableBatchStaysRetryableAndIsNeverDelivered() async throws {
        let malformed = HTTPResponse(statusCode: 200, body: Data("not json".utf8))
        let transport = ScriptedTransport([malformed, malformed])
        let harness = try await makeHarness(transport: transport)
        let connection = try await linked(harness)
        let listen = try #require(
            try await harness.store.insert(
                lastFMTestListen(),
                targets: [connection.id ?? -1],
            ),
        )

        harness.runtime.deliveryOutbox?.drain(connectionIDs: [connection.id ?? -1])

        let failed = await awaitDeliveries(harness.store, listen: listen) {
            $0.allSatisfy { $0.attempts == 1 }
        }
        #expect(failed.first?.state == .retrying)
        #expect(failed.first?.state != .delivered)

        harness.clock.advance(to: harness.clock.now.addingTimeInterval(30))
        let retried = await awaitDeliveries(harness.store, listen: listen) {
            $0.allSatisfy { $0.attempts == 2 }
        }
        #expect(retried.first?.state == .retrying)
        #expect(retried.first?.state != .delivered)
    }

    @Test func anAppCredentialRejectionSurfacesOnTheServicesState() async throws {
        let transport = ScriptedTransport([lastFMErrorResponse(code: 26)])
        let harness = try await makeHarness(transport: transport)
        let connection = try await linked(harness)
        let listen = try #require(
            try await harness.store.insert(
                lastFMTestListen(),
                targets: [connection.id ?? -1],
            ),
        )

        harness.runtime.deliveryOutbox?.drain(connectionIDs: [connection.id ?? -1])

        let failed = await awaitDeliveries(harness.store, listen: listen) {
            $0.allSatisfy { $0.attempts == 1 }
        }
        #expect(failed.first?.state == .retrying)
        #expect(harness.state.lastFMAppCredentialProblem == .suspendedKey)
        #expect(harness.state.connections.first?.authState == .needsSignIn)
    }

    @Test func theSessionKeyNeverReachesALogTheDatabaseOrPublishedState() async throws {
        let sessionKey = "lastfm-session-key-that-must-not-leak"
        var logged: [String] = []
        let transport = ScriptedTransport([lastFMScrobbleResponse(codes: [0])])
        let harness = try await makeHarness(
            transport: transport,
            connectionLog: { logged.append($0.description) },
            deliveryLog: { logged.append($0.description) },
        )
        let connection = try await linked(harness, credential: sessionKey)
        let listen = try #require(
            try await harness.store.insert(
                lastFMTestListen(),
                targets: [connection.id ?? -1],
            ),
        )
        harness.runtime.deliveryOutbox?.drain(connectionIDs: [connection.id ?? -1])
        _ = await awaitDeliveries(harness.store, listen: listen) {
            $0.allSatisfy { $0.state == .delivered }
        }

        #expect(!logged.joined(separator: "\n").contains(sessionKey))
        #expect(!String(describing: harness.state.connections).contains(sessionKey))
        #expect(
            try await harness.credentials.credential(forConnection: connection.id ?? -1) == sessionKey,
        )

        await harness.store.close()
        let storedBytes = try Data(contentsOf: harness.database.url)
        #expect(storedBytes.range(of: Data(sessionKey.utf8)) == nil)
    }
}
