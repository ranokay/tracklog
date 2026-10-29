import Foundation
import Testing
@testable import TracklogCore

@Suite("HUD stuck recovery")
@MainActor
struct HUDStuckRecoveryTests: CaptureTestHelpers {
    @Test func stuckCountsDeliveriesAcrossConnectionsAndRecoversWithTheDeliveredCount() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let credentials = MemoryCredentialStore()
        let clock = FakeClock(base)
        let probe = HUDProbe()
        let lastFM = RecordingDeliveryAdapter(kind: .lastFM)
        let brainz = RecordingDeliveryAdapter(kind: .listenBrainz)
        let lastFMConnection = try await saveHUDConnection(
            store,
            credentials: credentials,
            kind: .lastFM,
            base: base,
        )
        let brainzConnection = try await saveHUDConnection(
            store,
            credentials: credentials,
            kind: .listenBrainz,
            identity: "listener-listenbrainz",
            base: base,
        )
        let runtime = makeHUDRuntime(
            store: store,
            clock: clock,
            probe: probe,
            adapters: [lastFM, brainz],
            credentials: credentials,
        )
        await runtime.start()
        await turnMainActor(100)

        let listen = try #require(
            try await store.insert(
                deliveryListen(title: "One listen", base: base, start: -(25 * 60 * 60)),
                targets: [lastFMConnection.id ?? -1, brainzConnection.id ?? -1],
            ),
        )
        let insertedDeliveries = try await store.deliveries(for: listen.id ?? -1)
        #expect(insertedDeliveries.count == 2)
        for delivery in insertedDeliveries {
            try await store.markFailed(
                delivery.id,
                attempts: 1,
                at: base,
                nextAttemptAt: base.addingTimeInterval(10 * 24 * 60 * 60),
                error: "The service could not be reached.",
            )
        }
        let updatedDeliveries = try await store.deliveries(for: listen.id ?? -1)
        #expect(updatedDeliveries.map(\.state) == [.retrying, .retrying])
        await runtime.reloadDeliveryState()
        #expect(runtime.state.pendingQueue.count == 2)

        let stuck = try #require(probe.presentations.first)
        #expect(stuck.title == "2 scrobbles waiting", "one listen to two services is two deliveries")
        #expect(stuck.detail == "Across 2 services")
        #expect(stuck.spoken == "2 scrobbles are waiting across 2 services.")
        #expect(probe.presentations.count == 1)

        await runtime.reloadDeliveryState()
        #expect(probe.presentations.count == 1, "one card per session per stuck connection set")

        runtime.retryDeliveries(forConnection: lastFMConnection.id ?? -1)
        await eventually { probe.presentations.contains { $0.id == "hud.recovery.queue" } }

        let recovered = try #require(
            probe.presentations.first { $0.id == "hud.recovery.queue" },
        )
        #expect(recovered.spoken == "Last.fm is accepting scrobbles again. 1 sent.")
        #expect(recovered.priority == .low)
        #expect(recovered.duration == 2)
        #expect(
            probe.presentations.contains { $0.id == "hud.failure.stuck" && $0.title == "1 scrobble waiting" },
            "the remaining subset raises its own card after the recovery",
        )
    }

    @Test func aPartiallyDrainedBacklogKeepsTheRecoveryCountUntilTheQueueDrains() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let credentials = MemoryCredentialStore()
        let clock = FakeClock(base)
        let probe = HUDProbe()
        let adapter = RecordingDeliveryAdapter(
            kind: .lastFM,
            answers: [
                .results([.delivered(reference: nil)]),
                .failure(.rateLimited(retryAfter: 120)),
                .results([.delivered(reference: nil)]),
            ],
        )
        let connection = try await saveHUDConnection(
            store,
            credentials: credentials,
            kind: .lastFM,
            base: base,
        )
        let runtime = makeHUDRuntime(
            store: store,
            clock: clock,
            probe: probe,
            adapters: [adapter],
            credentials: credentials,
        )
        await runtime.start()
        await turnMainActor(100)

        try await insertHeldHUDPending(
            store,
            connection: connection,
            title: "Old",
            start: -(25 * 60 * 60),
            base: base,
        )
        try await insertHeldHUDPending(
            store,
            connection: connection,
            title: "Young",
            start: -(60 * 60),
            base: base,
        )
        await runtime.reloadDeliveryState()
        await eventually { probe.presentations.filter { $0.id == "hud.failure.stuck" }.count == 1 }

        runtime.retryDeliveries(forConnection: connection.id ?? -1)
        await eventually { runtime.state.pendingQueue.count == 1 }
        #expect(
            !probe.presentations.contains { $0.id == "hud.recovery.queue" },
            "the mixed-age backlog has not drained yet",
        )

        runtime.retryDeliveries(forConnection: connection.id ?? -1)
        await eventually { probe.presentations.contains { $0.id == "hud.recovery.queue" } }

        let recoveries = probe.presentations.filter { $0.id == "hud.recovery.queue" }
        #expect(recoveries.count == 1)
        #expect(recoveries.first?.spoken == "Last.fm is accepting scrobbles again. 2 sent.")
    }

    @Test func deletingTheRemainderDoesNotCountAsSent() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let credentials = MemoryCredentialStore()
        let clock = FakeClock(base)
        let probe = HUDProbe()
        let adapter = RecordingDeliveryAdapter(
            kind: .lastFM,
            answers: [
                .results([.delivered(reference: nil)]),
                .failure(.rateLimited(retryAfter: 120)),
            ],
        )
        let connection = try await saveHUDConnection(
            store,
            credentials: credentials,
            kind: .lastFM,
            base: base,
        )
        let runtime = makeHUDRuntime(
            store: store,
            clock: clock,
            probe: probe,
            adapters: [adapter],
            credentials: credentials,
        )
        await runtime.start()
        await turnMainActor(100)

        try await insertHeldHUDPending(
            store,
            connection: connection,
            title: "Old",
            start: -(25 * 60 * 60),
            base: base,
        )
        try await insertHeldHUDPending(
            store,
            connection: connection,
            title: "Young",
            start: -(60 * 60),
            base: base,
        )
        await runtime.reloadDeliveryState()
        await eventually { probe.presentations.filter { $0.id == "hud.failure.stuck" }.count == 1 }

        runtime.retryDeliveries(forConnection: connection.id ?? -1)
        await eventually { runtime.state.pendingQueue.count == 1 }
        let young = try #require(runtime.state.pendingQueue.groups.first?.items.first?.delivery)
        await runtime.deleteDelivery(young)
        await eventually { probe.presentations.contains { $0.id == "hud.recovery.queue" } }

        let recoveries = probe.presentations.filter { $0.id == "hud.recovery.queue" }
        #expect(recoveries.count == 1)
        #expect(recoveries.first?.spoken == "Last.fm is accepting scrobbles again. 1 sent.")
    }

    @Test func disabledAndNeedsSignInQueuesAreNotStuck() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let credentials = MemoryCredentialStore()
        let clock = FakeClock(base)
        let probe = HUDProbe()
        let lastFM = RecordingDeliveryAdapter(kind: .lastFM)
        let brainz = RecordingDeliveryAdapter(kind: .listenBrainz)
        let disabled = try await saveHUDConnection(
            store,
            credentials: credentials,
            kind: .lastFM,
            base: base,
            isEnabled: false,
        )
        let needsSignIn = try await saveHUDConnection(
            store,
            credentials: credentials,
            kind: .listenBrainz,
            identity: "listener-listenbrainz",
            base: base,
            authState: .needsSignIn,
        )
        try await insertHeldHUDPending(
            store,
            connection: disabled,
            title: "Disabled",
            start: -(30 * 60 * 60),
            base: base,
        )
        try await insertHeldHUDPending(
            store,
            connection: needsSignIn,
            title: "Signed out",
            start: -(30 * 60 * 60),
            base: base,
        )

        let runtime = makeHUDRuntime(
            store: store,
            clock: clock,
            probe: probe,
            adapters: [lastFM, brainz],
            credentials: credentials,
        )
        await runtime.start()

        #expect(probe.presentations.isEmpty)
        #expect(runtime.stuckEvaluationTask == nil)

        clock.advance(to: base.addingTimeInterval(2 * 24 * 60 * 60))
        await turnMainActor(100)
        #expect(probe.presentations.isEmpty)

        try await runtime.setConnectionEnabled(id: disabled.id ?? -1, enabled: true)
        await eventually { probe.presentations.count == 1 }
        #expect(probe.presentations.last?.id == "hud.failure.stuck")
        #expect(probe.presentations.last?.spoken == "1 scrobble is waiting for Last.fm, which is not accepting it.")
    }
}
