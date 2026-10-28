import Foundation
import Testing
@testable import TracklogCore

@Suite("Connections")
@MainActor
struct ConnectionServiceTests {
    private let base = Date(timeIntervalSince1970: 1_000_000)

    private func makeConnectionService(
        database: TemporaryDatabase,
        transport: any HTTPTransport,
        credentials: any CredentialStore = MemoryCredentialStore(),
        adapters: [any ServiceAdapter] = [],
        log: @escaping @MainActor (ConnectionEvent) -> Void = { _ in },
    ) throws -> (SQLiteListenStore, ConnectionService) {
        let store = try SQLiteListenStore(url: database.url)
        let service = ConnectionService(
            store: store,
            credentials: credentials,
            adapters: adapters + [ListenBrainzAdapter(transport: transport)],
            clock: FakeClock(base),
            log: log,
        )
        return (store, service)
    }

    @Test func linkingValidatesTheTokenAndMakesTheConnectionCurrent() async throws {
        let database = try TemporaryDatabase()
        let credentials = MemoryCredentialStore()
        var events: [ConnectionEvent] = []
        let transport = ScriptedTransport([listenBrainzValidResponse()])
        let (_, service) = try makeConnectionService(
            database: database,
            transport: transport,
            credentials: credentials,
            log: { events.append($0) },
        )

        let connection = try await service.link(kind: .listenBrainz, credential: " abc123\n")

        #expect(connection.id != nil)
        #expect(connection.kind == .listenBrainz)
        #expect(connection.endpoint == .listenBrainz)
        #expect(connection.identity == "listener")
        #expect(connection.displayName == "listener")
        #expect(connection.isEnabled)
        #expect(connection.authState == .signedIn)
        #expect(connection.createdAt == base)
        #expect(connection.lastUsedAt == base)
        #expect(service.connections == [connection])
        #expect(service.currentID == connection.id)
        #expect(service.currentConnection == connection)
        #expect(try await credentials.credential(forConnection: connection.id ?? -1) == "abc123")
        #expect(events == [.linked(kind: .listenBrainz, identity: "listener")])
        let requests = await transport.requests
        #expect(requests.first?.headers["Authorization"] == "Token abc123")
    }

    @Test func aRejectedTokenLeavesAnExistingConnectionAndItsCredentialAlone() async throws {
        let database = try TemporaryDatabase()
        let credentials = MemoryCredentialStore()
        let transport = ScriptedTransport([
            listenBrainzValidResponse(),
            HTTPResponse(statusCode: 401, body: Data("{}".utf8)),
        ])
        let (_, service) = try makeConnectionService(
            database: database,
            transport: transport,
            credentials: credentials,
        )
        let linked = try await service.link(kind: .listenBrainz, credential: "good")

        await #expect(throws: ServiceFailure.auth) {
            _ = try await service.link(kind: .listenBrainz, credential: "bad")
        }

        #expect(service.connections == [linked])
        #expect(service.currentID == linked.id)
        #expect(try await credentials.credential(forConnection: linked.id ?? -1) == "good")
    }

    @Test func aSecondConnectionOnTheSameEndpointIsRefused() async throws {
        let database = try TemporaryDatabase()
        let credentials = MemoryCredentialStore()
        let transport = ScriptedTransport([listenBrainzValidResponse(), listenBrainzValidResponse(user: "other")])
        let (_, service) = try makeConnectionService(
            database: database,
            transport: transport,
            credentials: credentials,
        )
        let first = try await service.link(kind: .listenBrainz, credential: "first")

        await #expect(
            throws: ConnectionError.duplicateEndpoint(kind: .listenBrainz, endpoint: .listenBrainz),
        ) {
            _ = try await service.link(kind: .listenBrainz, credential: "second")
        }

        #expect(service.connections == [first])
        #expect(service.currentID == first.id)
        #expect(try await credentials.credential(forConnection: first.id ?? -1) == "first")
    }

    @Test func differentKindsBothSurviveAndTheNewestBecomesCurrent() async throws {
        let database = try TemporaryDatabase()
        let transport = ScriptedTransport([listenBrainzValidResponse(user: "lb-user")])
        let lastFM = StubAdapter(
            kind: .lastFM,
            identity: ServiceIdentity(name: "lastfm-user"),
        )
        let (_, service) = try makeConnectionService(
            database: database,
            transport: transport,
            adapters: [lastFM],
        )

        let lastFMConnection = try await service.link(kind: .lastFM, credential: "lastfm-key")
        let listenBrainz = try await service.link(kind: .listenBrainz, credential: "lb-token")

        #expect(service.connections == [lastFMConnection, listenBrainz])
        #expect(service.connections.map(\.kind) == [.lastFM, .listenBrainz])
        #expect(service.currentID == listenBrainz.id)
    }

    @Test func theEnabledSwitchAndCurrentChoicePersistAcrossReload() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let credentials = MemoryCredentialStore()
        let transport = ScriptedTransport([listenBrainzValidResponse()])
        let lastFM = StubAdapter(kind: .lastFM, identity: ServiceIdentity(name: "lastfm-user"))
        let service = ConnectionService(
            store: store,
            credentials: credentials,
            adapters: [lastFM, ListenBrainzAdapter(transport: transport)],
            clock: FakeClock(base),
        )
        let first = try await service.link(kind: .lastFM, credential: "lastfm-key")
        let second = try await service.link(kind: .listenBrainz, credential: "lb-token")

        try await service.setEnabled(id: second.id ?? -1, enabled: false)
        try await service.setCurrent(first.id ?? -1)
        #expect(service.currentID == first.id)

        let reopenedStore = try SQLiteListenStore(url: database.url)
        let reloaded = ConnectionService(
            store: reopenedStore,
            credentials: credentials,
            adapters: [lastFM, ListenBrainzAdapter(transport: transport)],
            clock: FakeClock(base),
        )
        try await reloaded.load()

        #expect(reloaded.currentID == first.id)
        #expect(reloaded.connections.first(where: { $0.id == second.id })?.isEnabled == false)
    }

    @Test func aCredentialThatCannotBeSavedRollsTheConnectionBack() async throws {
        let database = try TemporaryDatabase()
        let transport = ScriptedTransport([listenBrainzValidResponse()])
        let (store, service) = try makeConnectionService(
            database: database,
            transport: transport,
            credentials: FailingCredentialStore(),
        )

        await #expect(throws: ConnectionError.credentialStorage) {
            _ = try await service.link(kind: .listenBrainz, credential: "token")
        }

        #expect(try await store.connections().isEmpty)
        #expect(try await store.currentConnectionID() == nil)
        #expect(service.connections.isEmpty)
        #expect(service.currentID == nil)
    }

    @Test func aCursorThatCannotBeSavedRollsTheLinkBack() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let credentials = MemoryCredentialStore()
        var events: [ConnectionEvent] = []
        let service = ConnectionService(
            store: CursorFailingStore(store),
            credentials: credentials,
            adapters: [ListenBrainzAdapter(transport: ScriptedTransport([listenBrainzValidResponse()]))],
            clock: FakeClock(base),
            log: { events.append($0) },
        )

        await #expect(throws: ConnectionError.currentCursor) {
            _ = try await service.link(kind: .listenBrainz, credential: "token")
        }

        #expect(try await store.connections().isEmpty)
        #expect(try await store.currentConnectionID() == nil)
        #expect(service.connections.isEmpty)
        #expect(service.currentID == nil)
        #expect(
            events == [
                .linkFailed(kind: .listenBrainz, reason: "current connection could not be saved"),
            ],
        )
    }

    @Test func anUnsupportedServiceIsRefusedBeforeTheNetwork() async throws {
        let database = try TemporaryDatabase()
        let transport = ScriptedTransport([])
        let (_, service) = try makeConnectionService(database: database, transport: transport)

        await #expect(throws: ConnectionError.unsupportedService(.lastFM)) {
            _ = try await service.link(kind: .lastFM, credential: "anything")
        }

        #expect(await transport.requests.isEmpty)
    }

    @Test func aSecretNeverReachesStoredConnectionsLogsOrExportableStores() async throws {
        let token = "lb-secret-token-9f3a"
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let credentials = MemoryCredentialStore()
        var logged: [String] = []
        let service = ConnectionService(
            store: store,
            credentials: credentials,
            adapters: [ListenBrainzAdapter(transport: ScriptedTransport([listenBrainzValidResponse()]))],
            clock: FakeClock(base),
            log: { logged.append($0.description) },
        )

        let connection = try await service.link(kind: .listenBrainz, credential: token)
        let loaded = try #require(service.connections.first)

        #expect(try await credentials.credential(forConnection: connection.id ?? -1) == token)
        #expect(!String(describing: loaded).contains(token))
        #expect(!logged.joined(separator: "\n").contains(token))

        // Export (#48) reads the durable stores, never the credential store.
        // Every store it may read is asserted here, so a future field cannot
        // smuggle a credential into the document.
        let exportableStores = try await [
            String(describing: store.connections()),
            String(describing: store.apps()),
            String(describing: store.edits()),
            String(describing: store.blocks()),
        ]
        .joined(separator: "\n")
        #expect(!exportableStores.contains(token))

        await store.close()
        let storedBytes = try Data(contentsOf: database.url)
        #expect(storedBytes.range(of: Data(token.utf8)) == nil)
    }
}
