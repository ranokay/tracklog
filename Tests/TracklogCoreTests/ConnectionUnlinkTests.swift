import Foundation
import Testing
@testable import TracklogCore

@Suite("Connection unlink")
@MainActor
struct ConnectionUnlinkTests {
    @Test func unlinkAbandonsPendingRowsKeepsHistoryAndDeletesTheCredential() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let credentials = MemoryCredentialStore()
        let adapter = RecordingDeliveryAdapter()
        let connection = try await savedConnection(store, authState: .signedIn)
        try await credentials.saveCredential("token", forConnection: connection.id ?? -1)
        let held = try await holdPendingDelivery(store, connection: connection, title: "Held")
        let delivered = try #require(
            try await store.insert(
                deliveryListen(title: "Delivered", base: connectionLifecycleBase, start: 10),
                targets: [connection.id ?? -1],
            ),
        )
        let deliveredRow = try #require(try await store.deliveries(for: delivered.id ?? -1).first)
        try await store.markDelivered(deliveredRow.id, at: connectionLifecycleBase, reference: nil)
        let state = TracklogAppState()
        let runtime = makeConnectionRuntime(
            store: store,
            credentials: credentials,
            adapters: [adapter],
            state: state,
        )
        await runtime.start()

        let unlinked = try await runtime.unlinkConnection(id: connection.id ?? -1)

        #expect(unlinked.abandonedDeliveries == 1)
        #expect(unlinked.connection.identity == "listener")
        #expect(state.connections.isEmpty)
        #expect(state.currentConnectionID == nil)
        #expect(try await credentials.credential(forConnection: connection.id ?? -1) == nil)
        #expect(try await store.connections().isEmpty)
        #expect(try await store.count() == 2, "local history keeps both listens")

        let abandoned = try await store.deliveries(for: held.id ?? -1)
        #expect(abandoned.map(\.state) == [.abandoned])
        #expect(abandoned.first?.abandonedReason == ConnectionService.unlinkReason)
        #expect(abandoned.first?.connectionID == nil, "the row survives the deleted connection")
        #expect(abandoned.first?.serviceKind == .listenBrainz, "history still names the service")

        let kept = try await store.deliveries(for: delivered.id ?? -1)
        #expect(kept.map(\.state) == [.delivered])
        #expect(kept.first?.serviceKind == .listenBrainz)
        let summary = DeliverySummary(kept)
        #expect(
            summary.accessibilityValue(connections: [])
                == "delivered to ListenBrainz",
        )
    }

    @Test func choosingAConnectionCountsAsUseForTheFallback() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let credentials = MemoryCredentialStore()
        let clock = FakeClock(connectionLifecycleBase)
        let service = ConnectionService(
            store: store,
            credentials: credentials,
            deliveries: store,
            adapters: [
                StubAdapter(kind: .lastFM, identity: ServiceIdentity(name: "unused")),
                StubAdapter(kind: .libreFM, identity: ServiceIdentity(name: "unused")),
                StubAdapter(kind: .listenBrainz, identity: ServiceIdentity(name: "unused")),
            ],
            clock: clock,
        )

        let first = try await service.linkVerified(
            kind: .lastFM,
            credential: "lastfm",
            identity: ServiceIdentity(name: "first"),
        )
        clock.advance(to: connectionLifecycleBase.addingTimeInterval(10))
        _ = try await service.linkVerified(
            kind: .libreFM,
            credential: "librefm",
            identity: ServiceIdentity(name: "second"),
        )
        clock.advance(to: connectionLifecycleBase.addingTimeInterval(20))
        let current = try await service.linkVerified(
            kind: .listenBrainz,
            credential: "brainz",
            identity: ServiceIdentity(name: "third"),
        )

        // Choosing the first connection is the most recent use, so it must win
        // over the second, which was only linked later.
        clock.advance(to: connectionLifecycleBase.addingTimeInterval(30))
        try await service.setCurrent(first.id)
        clock.advance(to: connectionLifecycleBase.addingTimeInterval(40))
        try await service.setCurrent(current.id)

        _ = try await service.unlink(id: current.id ?? -1)

        #expect(service.currentID == first.id)
        #expect(try await store.currentConnectionID() == first.id)
    }

    @Test func aFailedCredentialDeletionLeavesTheQueueIntact() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let credentials = DeleteFailingCredentialStore(deletesToFail: 1)
        let connection = try await savedConnection(store, authState: .signedIn)
        try await credentials.saveCredential("token", forConnection: connection.id ?? -1)
        let listen = try await holdPendingDelivery(store, connection: connection)
        let state = TracklogAppState()
        let runtime = makeConnectionRuntime(
            store: store,
            credentials: credentials,
            adapters: [],
            state: state,
        )
        await runtime.start()

        await #expect(throws: DatabaseError.self) {
            _ = try await runtime.unlinkConnection(id: connection.id ?? -1)
        }

        #expect(state.connections.map(\.identity) == ["listener"])
        #expect(try await credentials.credential(forConnection: connection.id ?? -1) == "token")
        let deliveries = try await store.deliveries(for: listen.id ?? -1)
        #expect(deliveries.map(\.state) == [.retrying], "nothing is abandoned when unlink stops early")
        #expect(try await store.count() == 1)
    }

    @Test func theUnlinkCountReadsOnlyTheConnectionPendingRows() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let credentials = MemoryCredentialStore()
        let first = try await savedConnection(store, kind: .lastFM, identity: "first", authState: .signedIn)
        let second = try await savedConnection(store, identity: "second", authState: .signedIn)
        try await credentials.saveCredential("first", forConnection: first.id ?? -1)
        try await credentials.saveCredential("second", forConnection: second.id ?? -1)
        _ = try await holdPendingDelivery(store, connection: first, title: "One")
        _ = try await holdPendingDelivery(store, connection: first, title: "Two")
        _ = try await holdPendingDelivery(store, connection: second, title: "Other")
        let state = TracklogAppState()
        let runtime = makeConnectionRuntime(
            store: store,
            credentials: credentials,
            adapters: [],
            state: state,
        )
        await runtime.start()

        #expect(await runtime.pendingDeliveryCount(forConnection: first.id ?? -1) == 2)
        #expect(await runtime.pendingDeliveryCount(forConnection: second.id ?? -1) == 1)
    }

    @Test func unlinkingTheCurrentConnectionFallsBackToTheMostRecentlyUsedOne() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let credentials = MemoryCredentialStore()
        let older = try await savedConnection(
            store,
            kind: .lastFM,
            identity: "older",
            authState: .signedIn,
            lastUsedAt: connectionLifecycleBase.addingTimeInterval(10),
        )
        let newer = try await savedConnection(
            store,
            identity: "newer",
            authState: .signedIn,
            lastUsedAt: connectionLifecycleBase.addingTimeInterval(20),
        )
        try await credentials.saveCredential("older-token", forConnection: older.id ?? -1)
        try await credentials.saveCredential("newer-token", forConnection: newer.id ?? -1)
        let state = TracklogAppState()
        let runtime = makeConnectionRuntime(
            store: store,
            credentials: credentials,
            adapters: [],
            state: state,
        )
        await runtime.start()
        try await runtime.setCurrentConnection(newer.id)
        #expect(state.currentConnectionID == newer.id)

        _ = try await runtime.unlinkConnection(id: newer.id ?? -1)

        #expect(state.currentConnectionID == older.id)
        #expect(try await store.currentConnectionID() == older.id)
        #expect(state.currentConnection?.identity == "older")

        _ = try await runtime.unlinkConnection(id: older.id ?? -1)

        #expect(state.currentConnectionID == nil)
        #expect(try await store.currentConnectionID() == nil)
    }

    @Test func relinkingAfterUnlinkNeverResumesAbandonedRows() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let credentials = MemoryCredentialStore()
        let adapter = RecordingDeliveryAdapter()
        let connection = try await savedConnection(store, authState: .signedIn)
        try await credentials.saveCredential("token", forConnection: connection.id ?? -1)
        let listen = try await holdPendingDelivery(store, connection: connection)
        let state = TracklogAppState()
        let runtime = makeConnectionRuntime(
            store: store,
            credentials: credentials,
            adapters: [adapter],
            state: state,
        )
        await runtime.start()

        _ = try await runtime.unlinkConnection(id: connection.id ?? -1)
        let relinked = try await runtime.link(kind: .listenBrainz, credential: "token")

        #expect(relinked.id != connection.id)
        let deliveries = try await store.deliveries(for: listen.id ?? -1)
        #expect(deliveries.map(\.state) == [.abandoned])
        await turnMainActor()
        #expect(await adapter.batches.isEmpty, "a re-link does not backfill abandoned rows")
    }

    @Test func upgradingAStoredDeliveryKeepsItWhenItsConnectionIsUnlinked() async throws {
        let database = try TemporaryDatabase()
        let older = try SQLiteListenStore(
            url: database.url,
            migrations: Array(SQLiteListenStore.schemaMigrations.prefix(7)),
        )
        let connection = try await older.save(
            Connection(
                kind: .lastFM,
                endpoint: .lastFM,
                identity: "listener",
                createdAt: connectionLifecycleBase,
            ),
        )
        let listen = try database.insertLegacyListen(
            deliveryListen(title: "One", base: connectionLifecycleBase),
        )
        try database.insertLegacyDelivery(
            listenID: listen.id ?? -1,
            connectionID: connection.id ?? -1,
        )
        await older.close()

        let upgraded = try SQLiteListenStore(url: database.url)
        let deliveries = try await upgraded.deliveries(for: listen.id ?? -1)
        #expect(deliveries.map(\.serviceKind) == [.lastFM])
        #expect(deliveries.map(\.connectionID) == [connection.id])

        try await upgraded.deleteConnection(id: connection.id ?? -1)

        let kept = try await upgraded.deliveries(for: listen.id ?? -1)
        #expect(kept.count == 1)
        #expect(kept.first?.connectionID == nil)
        #expect(kept.first?.serviceKind == .lastFM)
        #expect(try await upgraded.count() == 1)
    }
}
