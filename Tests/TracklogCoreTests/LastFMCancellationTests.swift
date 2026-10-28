import Foundation
import Testing
@testable import TracklogCore

/// A real connection store whose insert suspends, so a test can cancel a link
/// while it is being written.
actor SuspendingConnectionStore: ConnectionStore {
    private let base: SQLiteListenStore
    private var saveContinuation: CheckedContinuation<Void, Never>?
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var didStartSaving = false

    init(_ base: SQLiteListenStore) {
        self.base = base
    }

    func connections() async throws -> [Connection] {
        try await base.connections()
    }

    func save(_ connection: Connection) async throws -> Connection {
        didStartSaving = true
        startedContinuation?.resume()
        startedContinuation = nil
        await withCheckedContinuation { saveContinuation = $0 }
        return try await base.save(connection)
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

    func waitUntilSaving() async {
        guard !didStartSaving else { return }
        await withCheckedContinuation { startedContinuation = $0 }
    }

    func resumeSaving() {
        saveContinuation?.resume()
        saveContinuation = nil
    }
}

@Suite("Last.fm cancellation")
@MainActor
struct LastFMCancellationTests {
    private let baseDate = Date(timeIntervalSince1970: 1_000_000)

    @Test func aCancelledLinkRemovesItsHalfMadeConnectionAndCredential() async throws {
        let database = try TemporaryDatabase()
        let base = try SQLiteListenStore(url: database.url)
        let store = SuspendingConnectionStore(base)
        let credentials = MemoryCredentialStore()
        let adapter = LastFMAdapter(
            transport: ScriptedTransport([]),
            appCredentials: lastFMTestCredentials,
        )
        let service = ConnectionService(
            store: store,
            credentials: credentials,
            adapters: [adapter],
            clock: FakeClock(baseDate),
        )

        let task = Task {
            try await service.linkVerified(
                kind: .lastFM,
                credential: "session-key",
                identity: ServiceIdentity(name: "listener"),
            )
        }
        await store.waitUntilSaving()
        task.cancel()
        await store.resumeSaving()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }

        #expect(try await base.connections().isEmpty)
        #expect(try await base.currentConnectionID() == nil)
        #expect(try await credentials.credential(forConnection: 1) == nil)
        #expect(service.connections.isEmpty)
        #expect(service.currentID == nil)
    }
}
