import Foundation
import Testing
@testable import TracklogCore

@Suite("HUD stuck threshold")
@MainActor
struct HUDStuckThresholdTests: CaptureTestHelpers {
    @Test func aStuckQueuePresentAtActivationStaysSilentAndDoesNotReschedule() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let credentials = MemoryCredentialStore()
        let clock = FakeClock(base)
        let probe = HUDProbe()
        let adapter = RecordingDeliveryAdapter(kind: .listenBrainz)
        let connection = try await saveHUDConnection(
            store,
            credentials: credentials,
            kind: .listenBrainz,
            base: base,
        )
        try await insertHeldHUDPending(
            store,
            connection: connection,
            title: "Old",
            start: -(25 * 60 * 60),
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

        #expect(probe.presentations.isEmpty, "an already-stuck queue raises no launch HUD")
        #expect(runtime.stuckEvaluationTask == nil, "a past deadline is never rescheduled")

        // The launch baseline is part of this activation session's seen sets.
        // Even after the queue empties and an identical set forms again, the
        // session must not raise the card.
        let baseline = try #require(try await store.pendingDeliveries().first)
        await runtime.deleteDelivery(baseline.delivery)
        try await insertHeldHUDPending(
            store,
            connection: connection,
            title: "Again",
            start: -(25 * 60 * 60),
            base: base,
        )
        await runtime.reloadDeliveryState()
        #expect(probe.presentations.isEmpty, "the launch set stays seen for the session")

        clock.advance(to: base.addingTimeInterval(2 * 24 * 60 * 60))
        await turnMainActor(100)
        #expect(probe.presentations.isEmpty)

        await runtime.reloadDeliveryState()
        #expect(probe.presentations.isEmpty, "a standing stuck set is not repeated")
        #expect(runtime.stuckEvaluationTask == nil)
    }

    @Test func aQueueCrossingTwentyFourHoursRaisesWithoutOtherActivity() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let credentials = MemoryCredentialStore()
        let clock = FakeClock(base)
        let probe = HUDProbe()
        let adapter = RecordingDeliveryAdapter(kind: .listenBrainz)
        let connection = try await saveHUDConnection(
            store,
            credentials: credentials,
            kind: .listenBrainz,
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
            title: "Crossing",
            start: -(24 * 60 * 60) + 1,
            base: base,
        )
        await runtime.reloadDeliveryState()

        #expect(probe.presentations.isEmpty)
        #expect(runtime.stuckEvaluationTask != nil, "the upcoming threshold schedules a wake")

        clock.advance(to: base.addingTimeInterval(1))
        await turnMainActor(100)
        #expect(probe.presentations.isEmpty, "exactly 24 hours is not strictly older")

        clock.advance(to: base.addingTimeInterval(2))
        await eventually { probe.presentations.count == 1 }

        let stuck = try #require(probe.presentations.first)
        #expect(stuck.id == "hud.failure.stuck")
        #expect(stuck.title == "1 scrobble waiting")
        #expect(stuck.spoken == "1 scrobble is waiting for ListenBrainz, which is not accepting it.")
        #expect(probe.announcements == [stuck.spoken])
        #expect(runtime.stuckEvaluationTask == nil, "the crossed deadline is not rescheduled")

        clock.advance(to: base.addingTimeInterval(60 * 60))
        await turnMainActor(100)
        #expect(probe.presentations.count == 1, "the same stuck set does not repeat")
    }

    @Test func stopAndRestartCancelTheOldThresholdWake() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let credentials = MemoryCredentialStore()
        let clock = FakeClock(base)
        let probe = HUDProbe()
        let adapter = RecordingDeliveryAdapter(kind: .listenBrainz)
        let connection = try await saveHUDConnection(
            store,
            credentials: credentials,
            kind: .listenBrainz,
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
            title: "Crossing",
            start: -(24 * 60 * 60) + 10,
            base: base,
        )
        await runtime.reloadDeliveryState()
        #expect(runtime.stuckEvaluationTask != nil)

        runtime.stop()
        #expect(runtime.stuckEvaluationTask == nil)

        clock.advance(to: base.addingTimeInterval(2 * 24 * 60 * 60))
        await turnMainActor(100)
        #expect(probe.presentations.isEmpty, "the stopped generation cannot wake")

        await runtime.start()
        #expect(probe.presentations.isEmpty, "the now old queue is a new activation baseline")
        #expect(runtime.stuckEvaluationTask == nil)
    }
}
