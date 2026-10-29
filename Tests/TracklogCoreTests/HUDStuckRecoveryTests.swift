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
        await eventually { probe.presentations.count == 2 }

        let recovered = try #require(probe.presentations.last)
        #expect(recovered.id == "hud.recovery.queue")
        #expect(recovered.spoken == "Last.fm is accepting scrobbles again. 1 sent.")
        #expect(recovered.priority == .low)
        #expect(recovered.duration == 2)
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

    @Test func signedInRecoveryReportsTheDeliveredCount() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let credentials = MemoryCredentialStore()
        let clock = FakeClock(base)
        let probe = HUDProbe()
        let adapter = RecordingDeliveryAdapter(kind: .lastFM)
        let connection = try await saveHUDConnection(
            store,
            credentials: credentials,
            kind: .lastFM,
            base: base,
            authState: .needsSignIn,
        )
        try await credentials.saveCredential("old-token", forConnection: connection.id ?? -1)
        _ = try await insertHUDPending(
            store,
            connection: connection,
            title: "Held",
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
        #expect(probe.presentations.isEmpty)

        _ = try await runtime.reauthenticate(
            id: connection.id ?? -1,
            credential: "new-token",
            identity: ServiceIdentity(name: "listener"),
            confirmReplacement: { _, _, _ in false },
        )
        await eventually { probe.presentations.count == 1 }

        let recovery = try #require(probe.presentations.first)
        #expect(recovery.id == "hud.recovery.signin")
        #expect(recovery.spoken == "Last.fm reconnected. 1 scrobble sent.")
        #expect(recovery.priority == .low)
        #expect(probe.announcements == [recovery.spoken])
    }
}
