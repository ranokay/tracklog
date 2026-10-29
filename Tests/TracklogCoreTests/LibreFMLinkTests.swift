import Foundation
import Testing
@testable import TracklogCore

@Suite("Libre.fm links")
@MainActor
struct LibreFMLinkTests {
    private let base = Date(timeIntervalSince1970: 1_000_000)

    private func makeService(
        database: TemporaryDatabase,
        credentials: MemoryCredentialStore = MemoryCredentialStore(),
    ) throws -> ConnectionService {
        try ConnectionService(
            store: SQLiteListenStore(url: database.url),
            credentials: credentials,
            adapters: [LibreFMAdapter(transport: ScriptedTransport([]))],
            clock: FakeClock(base),
        )
    }

    @Test func aBrowserLinkStoresTheRootTheListenerEntered() async throws {
        let database = try TemporaryDatabase()
        let credentials = MemoryCredentialStore()
        let service = try makeService(database: database, credentials: credentials)
        let root = try #require(ServiceEndpoint(normalizing: "https://music.example.org/gnufm/"))

        let connection = try await service.linkVerified(
            kind: .libreFM,
            credential: "session-key",
            identity: ServiceIdentity(name: "listener"),
            endpoint: root,
        )

        #expect(connection.kind == .libreFM)
        #expect(connection.endpoint.description == "https://music.example.org/gnufm")
        #expect(connection.identity == "listener")
        #expect(service.currentID == connection.id)
        #expect(try await credentials.credential(forConnection: connection.id ?? -1) == "session-key")

        let reloaded = try makeService(database: database, credentials: credentials)
        try await reloaded.load()
        #expect(reloaded.connections.map(\.endpoint) == [root])
    }

    @Test func aLinkWithNoEndpointUsesTheDefaultRoot() async throws {
        let database = try TemporaryDatabase()
        let service = try makeService(database: database)

        let connection = try await service.linkVerified(
            kind: .libreFM,
            credential: "session-key",
            identity: ServiceIdentity(name: "listener"),
        )

        #expect(connection.endpoint == .libreFM)
        #expect(connection.endpoint.description == "https://libre.fm")
    }

    @Test func twoGNUFMRootsBothSurviveAndTheSameRootIsRefused() async throws {
        let database = try TemporaryDatabase()
        let service = try makeService(database: database)
        let first = try #require(ServiceEndpoint(normalizing: "https://one.example"))
        let second = try #require(ServiceEndpoint(normalizing: "https://two.example"))

        _ = try await service.linkVerified(
            kind: .libreFM,
            credential: "key-one",
            identity: ServiceIdentity(name: "listener"),
            endpoint: first,
        )
        _ = try await service.linkVerified(
            kind: .libreFM,
            credential: "key-two",
            identity: ServiceIdentity(name: "listener"),
            endpoint: second,
        )

        #expect(service.connections.map(\.endpoint) == [first, second])
        await #expect(
            throws: ConnectionError.duplicateEndpoint(kind: .libreFM, endpoint: second),
        ) {
            _ = try await service.linkVerified(
                kind: .libreFM,
                credential: "key-three",
                identity: ServiceIdentity(name: "listener"),
                endpoint: second,
            )
        }
    }
}
