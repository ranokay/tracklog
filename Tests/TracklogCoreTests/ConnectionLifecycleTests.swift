import Foundation
import Testing
@testable import TracklogCore

@Suite("Connection re-auth")
@MainActor
struct ConnectionReauthenticationTests {
    @Test func sameIdentitySignInClearsNeedsSignInKeepsAndDrainsPendingDeliveries() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let credentials = MemoryCredentialStore()
        let adapter = RecordingDeliveryAdapter()
        let connection = try await savedConnection(store)
        try await credentials.saveCredential("old-token", forConnection: connection.id ?? -1)
        let listen = try await holdPendingDelivery(store, connection: connection)
        let state = TracklogAppState()
        let runtime = makeConnectionRuntime(
            store: store,
            credentials: credentials,
            adapters: [adapter],
            state: state,
        )
        await runtime.start()

        let updated = try await runtime.reauthenticate(
            id: connection.id ?? -1,
            credential: "new-token",
            identity: ServiceIdentity(name: "listener"),
            confirmReplacement: { _, _, _ in
                Issue.record("the same identity must not ask for replacement")
                return false
            },
        )

        #expect(updated.id == connection.id)
        #expect(updated.identity == "listener")
        #expect(updated.authState == .signedIn)
        #expect(updated.lastUsedAt == connectionLifecycleBase)
        #expect(state.connection(id: connection.id ?? -1)?.authState == .signedIn)
        #expect(try await credentials.credential(forConnection: connection.id ?? -1) == "new-token")
        #expect(try await store.connections() == [updated])

        let batches = await awaitBatches(adapter, count: 1)
        #expect(batches.count == 1, "a held delivery drains after the sign-in")
        let deliveries = await awaitDeliveries(store, listen: listen) {
            $0.allSatisfy { $0.state == .delivered }
        }
        #expect(deliveries.map(\.state) == [.delivered])
        #expect(try await store.count() == 1)
    }

    @Test func aListenBrainzTokenSignInValidatesTheNewCredential() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let credentials = MemoryCredentialStore()
        let connection = try await savedConnection(store, identity: "listener-listenbrainz")
        try await credentials.saveCredential("old-token", forConnection: connection.id ?? -1)
        let state = TracklogAppState()
        let runtime = makeConnectionRuntime(
            store: store,
            credentials: credentials,
            adapters: [RecordingDeliveryAdapter()],
            state: state,
        )
        await runtime.start()

        let updated = try await runtime.reauthenticate(
            id: connection.id ?? -1,
            credential: "fresh-token",
            confirmReplacement: { _, _, _ in false },
        )

        #expect(updated.authState == .signedIn)
        #expect(updated.identity == "listener-listenbrainz")
        #expect(try await credentials.credential(forConnection: connection.id ?? -1) == "fresh-token")
    }

    @Test func differentIdentityAsksAbandonsOldPendingDeliveriesAndReplacesTheAccount() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let credentials = MemoryCredentialStore()
        let adapter = RecordingDeliveryAdapter()
        let connection = try await savedConnection(store, identity: "old-listener")
        try await credentials.saveCredential("old-token", forConnection: connection.id ?? -1)
        let listen = try await holdPendingDelivery(store, connection: connection)
        let confirmed = ConnectionConfirmation()
        let state = TracklogAppState()
        let runtime = makeConnectionRuntime(
            store: store,
            credentials: credentials,
            adapters: [adapter],
            state: state,
        )
        await runtime.start()

        let updated = try await runtime.reauthenticate(
            id: connection.id ?? -1,
            credential: "new-token",
            identity: ServiceIdentity(name: "new-listener"),
            confirmReplacement: { existing, identity, pending in
                confirmed.record(existing: existing, identity: identity, pending: pending)
                return true
            },
        )

        #expect(confirmed.pending == [1])
        #expect(confirmed.existingIdentity == ["old-listener"])
        #expect(confirmed.newIdentity == ["new-listener"])
        #expect(updated.id == connection.id)
        #expect(updated.identity == "new-listener")
        #expect(updated.authState == .signedIn)
        #expect(state.connections.map(\.identity) == ["new-listener"])
        #expect(try await credentials.credential(forConnection: connection.id ?? -1) == "new-token")
        #expect(await adapter.batches.isEmpty, "the old account's pending rows are never sent")

        let deliveries = try await store.deliveries(for: listen.id ?? -1)
        #expect(deliveries.map(\.state) == [.abandoned])
        #expect(deliveries.first?.abandonedReason == ConnectionService.replacementReason)
        #expect(try await store.count() == 1)
        #expect(try await store.connections().map(\.identity) == ["new-listener"])
    }

    @Test func refusingTheReplacementChangesNothing() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let credentials = MemoryCredentialStore()
        let connection = try await savedConnection(store, identity: "old-listener")
        try await credentials.saveCredential("old-token", forConnection: connection.id ?? -1)
        let listen = try await holdPendingDelivery(store, connection: connection)
        let state = TracklogAppState()
        let runtime = makeConnectionRuntime(
            store: store,
            credentials: credentials,
            adapters: [RecordingDeliveryAdapter()],
            state: state,
        )
        await runtime.start()

        await #expect(throws: ConnectionError.reauthenticationCancelled) {
            _ = try await runtime.reauthenticate(
                id: connection.id ?? -1,
                credential: "new-token",
                identity: ServiceIdentity(name: "new-listener"),
                confirmReplacement: { _, _, _ in false },
            )
        }

        #expect(state.connections.map(\.identity) == ["old-listener"])
        #expect(try await credentials.credential(forConnection: connection.id ?? -1) == "old-token")
        let deliveries = try await store.deliveries(for: listen.id ?? -1)
        #expect(deliveries.map(\.state) == [.retrying])
    }
}
