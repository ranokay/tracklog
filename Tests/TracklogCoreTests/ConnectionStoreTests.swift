import Foundation
import Testing
@testable import TracklogCore

@Suite("Connection store")
struct ConnectionStoreTests {
    private let base = Date(timeIntervalSince1970: 1_000_000)

    private func connection(
        kind: ServiceKind = .listenBrainz,
        endpoint: ServiceEndpoint = .listenBrainz,
        identity: String = "listener",
        enabled: Bool = true,
        authState: ConnectionAuthState = .signedIn,
        created: TimeInterval = 0,
        used: TimeInterval? = nil,
    ) -> Connection {
        Connection(
            kind: kind,
            endpoint: endpoint,
            identity: identity,
            displayName: identity,
            isEnabled: enabled,
            authState: authState,
            createdAt: base.addingTimeInterval(created),
            lastUsedAt: base.addingTimeInterval(used ?? created),
        )
    }

    @Test func storesAndReadsBackEveryField() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let original = connection(
            identity: "listener",
            enabled: false,
            authState: .needsSignIn,
            created: 10,
            used: 20,
        )

        let saved = try await store.save(original)
        let loaded = try await store.connections()

        #expect(saved.id != nil)
        #expect(loaded == [saved])
        #expect(loaded.first?.kind == .listenBrainz)
        #expect(loaded.first?.endpoint == .listenBrainz)
        #expect(loaded.first?.identity == "listener")
        #expect(loaded.first?.displayName == "listener")
        #expect(loaded.first?.isEnabled == false)
        #expect(loaded.first?.authState == .needsSignIn)
        #expect(loaded.first?.createdAt == base.addingTimeInterval(10))
        #expect(loaded.first?.lastUsedAt == base.addingTimeInterval(20))
    }

    @Test func refusesTwoConnectionsOnTheSameKindAndEndpoint() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        _ = try await store.save(connection(identity: "first"))

        await #expect(
            throws: ConnectionError.duplicateEndpoint(kind: .listenBrainz, endpoint: .listenBrainz),
        ) {
            _ = try await store.save(connection(identity: "second", created: 10))
        }

        #expect(try await store.connections().count == 1)
    }

    @Test func differentKindsOnTheirOwnEndpointsBothSurvive() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)

        let lastFM = try await store.save(
            connection(kind: .lastFM, endpoint: .lastFM, identity: "lastfm-user"),
        )
        let listenBrainz = try await store.save(
            connection(kind: .listenBrainz, endpoint: .listenBrainz, identity: "lb-user", created: 10),
        )

        let loaded = try await store.connections()

        #expect(loaded == [lastFM, listenBrainz])
        #expect(Set(loaded.map(\.kind)) == [.lastFM, .listenBrainz])
    }

    @Test func theServicesStateReflectsTheEnabledSwitchAndAuthState() {
        var connection = connection()

        #expect(connection.status == .connected)
        connection.isEnabled = false
        #expect(connection.status == .paused)
        connection.authState = .needsSignIn
        #expect(connection.status == .needsSignIn)
        connection.isEnabled = true
        #expect(connection.status == .needsSignIn)
    }

    @Test func changingTheEnabledSwitchAndAuthStatePersists() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        var saved = try await store.save(connection())

        saved.isEnabled = false
        saved.authState = .needsSignIn
        saved.lastUsedAt = base.addingTimeInterval(500)
        _ = try await store.save(saved)

        let reloaded = try SQLiteListenStore(url: database.url)
        let loaded = try #require(try await reloaded.connections().first)
        #expect(loaded.isEnabled == false)
        #expect(loaded.authState == .needsSignIn)
        #expect(loaded.lastUsedAt == base.addingTimeInterval(500))
        #expect(loaded.createdAt == base)
    }

    @Test func currentConnectionPersistsAcrossReopen() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let first = try await store.save(connection(kind: .lastFM, endpoint: .lastFM))
        let second = try await store.save(connection(created: 10))
        try await store.setCurrentConnectionID(second.id)

        let reopened = try SQLiteListenStore(url: database.url)

        #expect(try await reopened.currentConnectionID() == second.id)
        try await reopened.setCurrentConnectionID(first.id)
        #expect(try await reopened.currentConnectionID() == first.id)
        try await reopened.setCurrentConnectionID(nil)
        #expect(try await reopened.currentConnectionID() == nil)
    }

    @Test func refusingAnUnknownCurrentConnectionChangesNothing() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let saved = try await store.save(connection())
        try await store.setCurrentConnectionID(saved.id)

        await #expect(throws: ConnectionError.unknownConnection(id: 9999)) {
            try await store.setCurrentConnectionID(9999)
        }

        #expect(try await store.currentConnectionID() == saved.id)
    }

    @Test func deletingTheCurrentConnectionClearsTheCursor() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let saved = try await store.save(connection())
        try await store.setCurrentConnectionID(saved.id)

        try await store.deleteConnection(id: saved.id ?? -1)

        #expect(try await store.connections().isEmpty)
        #expect(try await store.currentConnectionID() == nil)
    }

    @Test func aConnectionSurvivesAReopen() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let saved = try await store.save(connection())
        try await store.setCurrentConnectionID(saved.id)

        let reopened = try SQLiteListenStore(url: database.url)

        #expect(try await reopened.connections() == [saved])
        #expect(try await reopened.currentConnectionID() == saved.id)
    }
}
