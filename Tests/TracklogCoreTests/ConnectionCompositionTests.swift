import Foundation
import Testing
@testable import TracklogCore

@Suite("Connection composition")
@MainActor
struct ConnectionCompositionTests {
    private let base = Date(timeIntervalSince1970: 1_000_000)

    private func runtime(
        database: TemporaryDatabase,
        state: TracklogAppState,
        credentials: (any CredentialStore)?,
        adapters: [any ServiceAdapter],
        log: @escaping @MainActor (ConnectionEvent) -> Void = { _ in },
    ) -> CaptureRuntime {
        CaptureRuntime.open(
            state: state,
            databaseURL: database.url,
            clock: FakeClock(base),
            source: ReplayedNowPlaying(),
            settings: CaptureSettings(scrobblingEnabled: false),
            credentials: credentials,
            serviceAdapters: adapters,
            connectionLog: log,
        )
    }

    @Test func linkingThroughTheRuntimePublishesAndSurvivesRelaunch() async throws {
        let database = try TemporaryDatabase()
        let credentials = MemoryCredentialStore()
        let transport = ScriptedTransport([listenBrainzValidResponse()])
        var logged: [String] = []
        let state = TracklogAppState()
        let first = runtime(
            database: database,
            state: state,
            credentials: credentials,
            adapters: [ListenBrainzAdapter(transport: transport)],
            log: { logged.append($0.description) },
        )
        await first.start()

        let connection = try await first.link(kind: .listenBrainz, credential: "token-123")

        #expect(state.connections == [connection])
        #expect(state.currentConnectionID == connection.id)
        #expect(state.currentConnection == connection)
        #expect(state.connectionsFailure == nil)
        #expect(try await credentials.credential(forConnection: connection.id ?? -1) == "token-123")
        #expect(!logged.joined(separator: "\n").contains("token-123"))

        let relaunchedState = TracklogAppState()
        let relaunched = runtime(
            database: database,
            state: relaunchedState,
            credentials: credentials,
            adapters: [ListenBrainzAdapter(transport: transport)],
        )
        await relaunched.start()

        #expect(relaunchedState.connections == [connection])
        #expect(relaunchedState.currentConnectionID == connection.id)
    }

    @Test func enabledAndCurrentChangesReachThePublishedState() async throws {
        let database = try TemporaryDatabase()
        let credentials = MemoryCredentialStore()
        let transport = ScriptedTransport([listenBrainzValidResponse(user: "lb-user")])
        let lastFM = StubAdapter(kind: .lastFM, identity: ServiceIdentity(name: "lastfm-user"))
        let state = TracklogAppState()
        let runtime = runtime(
            database: database,
            state: state,
            credentials: credentials,
            adapters: [lastFM, ListenBrainzAdapter(transport: transport)],
        )
        await runtime.start()

        let first = try await runtime.link(kind: .lastFM, credential: "lastfm-key")
        let second = try await runtime.link(kind: .listenBrainz, credential: "lb-token")
        try await runtime.setConnectionEnabled(id: second.id ?? -1, enabled: false)
        try await runtime.setCurrentConnection(first.id)

        #expect(state.connections.map(\.kind) == [.lastFM, .listenBrainz])
        #expect(state.connections.first(where: { $0.id == second.id })?.isEnabled == false)
        #expect(state.currentConnectionID == first.id)
        #expect(state.currentConnection?.kind == .lastFM)
    }

    @Test func aFailedLinkStillPublishesARecoverableConnection() async throws {
        let database = try TemporaryDatabase()
        let baseStore = try SQLiteListenStore(url: database.url)
        let store = RecoveryFailingStore(baseStore, currentWritesToFail: 1, deletesToFail: 1)
        let state = TracklogAppState()
        let runtime = CaptureRuntime(
            state: state,
            clock: FakeClock(base),
            source: ReplayedNowPlaying(),
            store: store,
            allowlist: InMemoryAppAllowlist(),
            credentials: DeleteFailingCredentialStore(deletesToFail: 1),
            serviceAdapters: [
                ListenBrainzAdapter(transport: ScriptedTransport([listenBrainzValidResponse()])),
            ],
            settings: CaptureSettings(scrobblingEnabled: false),
        )
        await runtime.start()

        await #expect(throws: ConnectionError.currentCursor) {
            _ = try await runtime.link(kind: .listenBrainz, credential: "token")
        }

        let kept = try #require(state.connections.first)
        #expect(state.currentConnectionID == nil)

        try await runtime.setCurrentConnection(kept.id)
        #expect(state.currentConnectionID == kept.id)
    }

    @Test func aFailedLinkDoesNotClearAFailedConnectionLoad() async throws {
        let database = try TemporaryDatabase()
        let baseStore = try SQLiteListenStore(url: database.url)
        let store = LoadFailingStore(baseStore)
        let state = TracklogAppState()
        let runtime = CaptureRuntime(
            state: state,
            clock: FakeClock(base),
            source: ReplayedNowPlaying(),
            store: store,
            allowlist: InMemoryAppAllowlist(),
            credentials: MemoryCredentialStore(),
            serviceAdapters: [
                ListenBrainzAdapter(
                    transport: ScriptedTransport([
                        HTTPResponse(statusCode: 401, body: Data("{}".utf8)),
                    ]),
                ),
            ],
            settings: CaptureSettings(scrobblingEnabled: false),
        )
        await runtime.start()

        let failure = try #require(state.connectionsFailure)
        await #expect(throws: ServiceFailure.auth) {
            _ = try await runtime.link(kind: .listenBrainz, credential: "bad")
        }

        #expect(state.connectionsFailure == failure)
        #expect(state.failure?.stage == .connections)
    }

    @Test func withoutACredentialStoreLinkingIsUnavailable() async throws {
        let database = try TemporaryDatabase()
        let state = TracklogAppState()
        let runtime = runtime(
            database: database,
            state: state,
            credentials: nil,
            adapters: [],
        )
        await runtime.start()

        await #expect(throws: ConnectionError.unavailable) {
            _ = try await runtime.link(kind: .listenBrainz, credential: "token")
        }

        #expect(state.connections.isEmpty)
        #expect(state.currentConnectionID == nil)
    }
}
