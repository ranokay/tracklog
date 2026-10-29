import Foundation
import Testing
@testable import TracklogCore

@Suite("Connection unlink failures")
@MainActor
struct ConnectionUnlinkFailureTests {
    @Test func aFailedStoreUnlinkRestoresTheCredentialAndQueue() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let credentials = MemoryCredentialStore()
        let connection = try await savedConnection(store, authState: .signedIn)
        try await credentials.saveCredential("token", forConnection: connection.id ?? -1)
        let listen = try await holdPendingDelivery(store, connection: connection)
        let service = ConnectionService(
            store: FailingUnlinkStore(store),
            credentials: credentials,
            deliveries: store,
            adapters: [],
            clock: FakeClock(connectionLifecycleBase),
        )
        try await service.load()

        await #expect(throws: DatabaseError.self) {
            _ = try await service.unlink(id: connection.id ?? -1)
        }

        #expect(service.connections.map(\.identity) == ["listener"])
        #expect(try await credentials.credential(forConnection: connection.id ?? -1) == "token")
        let deliveries = try await store.deliveries(for: listen.id ?? -1)
        #expect(deliveries.map(\.state) == [.retrying])
        #expect(try await store.connections().count == 1)
    }
}

/// A real connection store whose atomic unlink always fails, so the service's
/// credential restore and queue preservation can be observed.
private actor FailingUnlinkStore: ConnectionStore, ConnectionUnlinkStore {
    private let base: SQLiteListenStore

    init(_ base: SQLiteListenStore) {
        self.base = base
    }

    func connections() async throws -> [Connection] {
        try await base.connections()
    }

    func save(_ connection: Connection) async throws -> Connection {
        try await base.save(connection)
    }

    func deleteConnection(id: Int64) async throws {
        try await base.deleteConnection(id: id)
    }

    func currentConnectionID() async throws -> Int64? {
        try await base.currentConnectionID()
    }

    func setCurrentConnectionID(_ id: Int64?) async throws {
        try await base.setCurrentConnectionID(id)
    }

    func unlinkConnection(id _: Int64, reason _: String) async throws -> Int {
        throw DatabaseError.unavailable("simulated unlink failure")
    }
}
