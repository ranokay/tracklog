import Foundation
import Testing
@testable import TracklogCore

@Suite("HUD stuck sets")
@MainActor
struct HUDStuckSetTests: CaptureTestHelpers {
    @Test func aStuckSetRepeatedAfterDrainingIsNotPresentedAgain() async throws {
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
            title: "First",
            start: -(25 * 60 * 60),
            base: base,
        )
        await runtime.reloadDeliveryState()
        await eventually { probe.presentations.contains { $0.id == "hud.failure.stuck" } }

        runtime.retryDeliveries(forConnection: connection.id ?? -1)
        await eventually { probe.presentations.contains { $0.id == "hud.recovery.queue" } }

        try await insertHeldHUDPending(
            store,
            connection: connection,
            title: "Second",
            start: -(25 * 60 * 60),
            base: base,
        )
        await runtime.reloadDeliveryState()
        await turnMainActor(20)

        #expect(
            probe.presentations.filter { $0.id == "hud.failure.stuck" }.count == 1,
            "the same connection set is presented once per activation session",
        )

        let remaining = try #require(try await store.pendingDeliveries().first)
        await runtime.deleteDelivery(remaining.delivery)
        runtime.stop()
        await runtime.start()
        await turnMainActor(100)
        try await insertHeldHUDPending(
            store,
            connection: connection,
            title: "Third",
            start: -(25 * 60 * 60),
            base: base,
        )
        await runtime.reloadDeliveryState()
        await eventually {
            probe.presentations.filter { $0.id == "hud.failure.stuck" }.count == 2
        }
    }

    @Test func aNewSubsetStuckSetIsPresentedEvenWhenItsIDsWereSeenInALargerSet() async throws {
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
                deliveryListen(title: "Old", base: base, start: -(25 * 60 * 60)),
                targets: [lastFMConnection.id ?? -1, brainzConnection.id ?? -1],
            ),
        )
        for delivery in try await store.deliveries(for: listen.id ?? -1) {
            try await store.markFailed(
                delivery.id,
                attempts: 1,
                at: base,
                nextAttemptAt: base.addingTimeInterval(10 * 24 * 60 * 60),
                error: "The service could not be reached.",
            )
        }
        await runtime.reloadDeliveryState()
        await eventually { probe.presentations.filter { $0.id == "hud.failure.stuck" }.count == 1 }

        runtime.retryDeliveries(forConnection: brainzConnection.id ?? -1)
        await eventually {
            probe.presentations.filter { $0.id == "hud.failure.stuck" }.count == 2
        }

        let stuckCards = probe.presentations.filter { $0.id == "hud.failure.stuck" }
        #expect(stuckCards.last?.spoken == "1 scrobble is waiting for Last.fm, which is not accepting it.")
        #expect(
            probe.presentations.contains {
                $0.id == "hud.recovery.queue"
                    && $0.spoken == "ListenBrainz is accepting scrobbles again. 1 sent."
            },
        )

        await runtime.reloadDeliveryState()
        await turnMainActor(20)
        #expect(
            probe.presentations.filter { $0.id == "hud.failure.stuck" }.count == 2,
            "the new subset is remembered after its first card",
        )
    }
}
