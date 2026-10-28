import Foundation
import Testing
@testable import TracklogCore

@Suite("Connection recovery")
@MainActor
struct ConnectionRecoveryTests {
    private let base = Date(timeIntervalSince1970: 1_000_000)

    @Test func aLoadWaitsForAnInFlightLink() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let credentials = SuspendingCredentialStore()
        let service = ConnectionService(
            store: store,
            credentials: credentials,
            adapters: [ListenBrainzAdapter(transport: ScriptedTransport([listenBrainzValidResponse()]))],
            clock: FakeClock(base),
        )

        let linkTask = Task { try await service.link(kind: .listenBrainz, credential: "token") }
        await credentials.waitUntilSaving()

        let (gateWait, gateWaitContinuation) = AsyncStream.makeStream(of: Void.self)
        service.onGateWait = { gateWaitContinuation.yield() }
        let loadTask = Task { try await service.load() }
        var gateWaitIterator = gateWait.makeAsyncIterator()
        _ = await gateWaitIterator.next()
        await credentials.resumeSaving()

        let linked = try await linkTask.value
        try await loadTask.value

        #expect(service.connections == [linked])
        #expect(service.currentID == linked.id)
        #expect(try await credentials.credential(forConnection: linked.id ?? -1) == "token")
    }

    @Test func aCredentialCleanupFailureIsRepairedOnLoad() async throws {
        let database = try TemporaryDatabase()
        let baseStore = try SQLiteListenStore(url: database.url)
        let service = ConnectionService(
            store: CleanupFailingStore(baseStore, deletesToFail: 1),
            credentials: FailingCredentialStore(),
            adapters: [ListenBrainzAdapter(transport: ScriptedTransport([listenBrainzValidResponse()]))],
            clock: FakeClock(base),
        )

        await #expect(throws: ConnectionError.credentialStorage) {
            _ = try await service.link(kind: .listenBrainz, credential: "token")
        }

        // The rollback could not delete the credentialless row.
        #expect(try await baseStore.connections().count == 1)
        #expect(service.connections.isEmpty)

        let repaired = ConnectionService(
            store: baseStore,
            credentials: MemoryCredentialStore(),
            adapters: [],
            clock: FakeClock(base),
        )
        try await repaired.load()

        #expect(try await baseStore.connections().isEmpty)
        #expect(repaired.connections.isEmpty)
        #expect(try await baseStore.currentConnectionID() == nil)

        let relinked = ConnectionService(
            store: baseStore,
            credentials: MemoryCredentialStore(),
            adapters: [ListenBrainzAdapter(transport: ScriptedTransport([listenBrainzValidResponse()]))],
            clock: FakeClock(base),
        )
        _ = try await relinked.link(kind: .listenBrainz, credential: "token")
        #expect(try await baseStore.connections().count == 1)
    }

    @Test func aCursorCleanupFailureKeepsTheConnectionRecoverable() async throws {
        let database = try TemporaryDatabase()
        let baseStore = try SQLiteListenStore(url: database.url)
        let credentials = DeleteFailingCredentialStore(deletesToFail: 1)
        let service = ConnectionService(
            store: RecoveryFailingStore(baseStore, currentWritesToFail: 1, deletesToFail: 1),
            credentials: credentials,
            adapters: [ListenBrainzAdapter(transport: ScriptedTransport([listenBrainzValidResponse()]))],
            clock: FakeClock(base),
        )

        await #expect(throws: ConnectionError.currentCursor) {
            _ = try await service.link(kind: .listenBrainz, credential: "token")
        }

        let kept = try #require(service.connections.first)
        #expect(service.currentID == nil)
        #expect(try await baseStore.connections() == [kept])
        #expect(try await credentials.credential(forConnection: kept.id ?? -1) == "token")

        try await service.setCurrent(kept.id)
        #expect(service.currentID == kept.id)
        #expect(try await baseStore.currentConnectionID() == kept.id)
    }

    @Test func aCredentiallessRowAfterCursorCleanupIsRepairedOnLoad() async throws {
        let database = try TemporaryDatabase()
        let baseStore = try SQLiteListenStore(url: database.url)
        let credentials = MemoryCredentialStore()
        let service = ConnectionService(
            store: RecoveryFailingStore(baseStore, currentWritesToFail: 1, deletesToFail: 1),
            credentials: credentials,
            adapters: [ListenBrainzAdapter(transport: ScriptedTransport([listenBrainzValidResponse()]))],
            clock: FakeClock(base),
        )

        await #expect(throws: ConnectionError.currentCursor) {
            _ = try await service.link(kind: .listenBrainz, credential: "token")
        }

        let orphan = try #require(try await baseStore.connections().first)
        #expect(service.connections.isEmpty)
        #expect(try await credentials.credential(forConnection: orphan.id ?? -1) == nil)

        let repaired = ConnectionService(
            store: baseStore,
            credentials: credentials,
            adapters: [],
            clock: FakeClock(base),
        )
        try await repaired.load()

        #expect(try await baseStore.connections().isEmpty)
        #expect(repaired.connections.isEmpty)
    }
}
