import Foundation
import Testing
@testable import TracklogCore

@Suite("Delivery backoff")
@MainActor
struct DeliveryBackoffTests {
    private func makeHarness(
        _ adapters: [any DeliveryAdapter],
        credentials: any CredentialStore = MemoryCredentialStore(),
    ) async throws -> DeliveryHarness {
        let base = Date(timeIntervalSince1970: 1_000_000)
        return try await DeliveryHarness(base: base, adapters: adapters, credentials: credentials)
    }

    @Test func aRateLimitHintWinsOnlyWhenItIsLater() async throws {
        let adapter = RecordingDeliveryAdapter(
            answers: [.failure(.rateLimited(retryAfter: 120))],
        )
        let harness = try await makeHarness([adapter])
        let connection = try await harness.connect(kind: .listenBrainz)
        let listen = try await harness.insert(
            deliveryListen(title: "Song", base: harness.clock.now),
            for: [connection],
        )

        harness.outbox.activate()

        let failed = await awaitDeliveries(harness.store, listen: listen) {
            $0.allSatisfy { $0.attempts == 1 }
        }
        #expect(failed.first?.nextAttemptAt == harness.clock.now.addingTimeInterval(120))
    }

    @Test func aRateLimitHintIsIgnoredWhenTheScheduleIsLater() async throws {
        let adapter = RecordingDeliveryAdapter(
            answers: [.failure(.rateLimited(retryAfter: 5))],
        )
        let harness = try await makeHarness([adapter])
        let connection = try await harness.connect(kind: .listenBrainz)
        let listen = try await harness.insert(
            deliveryListen(title: "Song", base: harness.clock.now),
            for: [connection],
        )

        harness.outbox.activate()

        let failed = await awaitDeliveries(harness.store, listen: listen) {
            $0.allSatisfy { $0.attempts == 1 }
        }
        #expect(failed.first?.nextAttemptAt == harness.clock.now.addingTimeInterval(30))
    }

    @Test func aFailureOnOneConnectionDoesNotHoldTheOther() async throws {
        let listenBrainz = RecordingDeliveryAdapter(answers: [.failure(.retryable)])
        let lastFM = RecordingDeliveryAdapter(kind: .lastFM)
        let harness = try await makeHarness([listenBrainz, lastFM])
        let brainz = try await harness.connect(kind: .listenBrainz)
        let lastFMConnection = try await harness.connect(kind: .lastFM)
        let held = try await harness.insert(
            deliveryListen(title: "Held", base: harness.clock.now, start: 0),
            for: [brainz],
        )
        let sent = try await harness.insert(
            deliveryListen(title: "Sent", base: harness.clock.now, start: 10),
            for: [lastFMConnection],
        )

        harness.outbox.activate()

        let heldDeliveries = await awaitDeliveries(harness.store, listen: held) {
            $0.allSatisfy { $0.state == .retrying }
        }
        let sentDeliveries = await awaitDeliveries(harness.store, listen: sent) {
            $0.allSatisfy { $0.state == .delivered }
        }
        #expect(heldDeliveries.map(\.state) == [.retrying])
        #expect(sentDeliveries.map(\.state) == [.delivered])
    }

    @Test func anUnreadableCredentialBacksOffWithoutChangingAuthState() async throws {
        let credentials = UnreadableCredentialStore()
        let adapter = RecordingDeliveryAdapter()
        let harness = try await makeHarness([adapter], credentials: credentials)
        let connection = try await harness.connect(kind: .listenBrainz)
        let listen = try await harness.insert(
            deliveryListen(title: "Song", base: harness.clock.now),
            for: [connection],
        )

        harness.outbox.activate()

        let failed = await awaitDeliveries(harness.store, listen: listen) {
            $0.allSatisfy { $0.attempts == 1 }
        }
        #expect(failed.first?.state == .retrying)
        #expect(harness.service.connections.first?.authState == .signedIn)

        await credentials.allowReads()
        harness.outbox.retry(connectionID: connection.id ?? -1)
        let delivered = await awaitDeliveries(harness.store, listen: listen) {
            $0.allSatisfy { $0.state == .delivered }
        }
        #expect(delivered.map(\.state) == [.delivered])
    }

    @Test func aFailedStateWriteDoesNotResubmitInTheSameDrain() async throws {
        let database = try TemporaryDatabase()
        let baseStore = try SQLiteListenStore(url: database.url)
        let store = FailingDeliveryStore(baseStore, failInsert: false, deliveredWritesToFail: 1)
        let credentials = MemoryCredentialStore()
        let adapter = RecordingDeliveryAdapter()
        let clock = FakeClock(Date(timeIntervalSince1970: 1_000_000))
        let connectionService = ConnectionService(
            store: store,
            credentials: credentials,
            adapters: [adapter],
            clock: clock,
        )
        let outbox = DeliveryOutbox(
            store: store,
            connections: connectionService,
            credentials: credentials,
            adapters: [adapter],
            clock: clock,
        )
        let connection = try await store.save(
            Connection(
                kind: .listenBrainz,
                endpoint: .listenBrainz,
                identity: "listener",
                createdAt: clock.now,
            ),
        )
        try await credentials.saveCredential("token", forConnection: connection.id ?? -1)
        try await connectionService.load()
        _ = try await store.insert(
            deliveryListen(title: "Song", base: clock.now),
            targets: [connection.id ?? -1],
        )

        outbox.activate()

        let batches = await awaitBatches(adapter, count: 1)
        #expect(batches.count == 1)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await adapter.batches.count == 1)

        clock.advance(to: clock.now.addingTimeInterval(29))
        await turnMainActor()
        #expect(await adapter.batches.count == 1, "a failed state write backs off locally")
        clock.advance(to: clock.now.addingTimeInterval(1))
        #expect(await awaitBatches(adapter, count: 2).count == 2)
    }
}
