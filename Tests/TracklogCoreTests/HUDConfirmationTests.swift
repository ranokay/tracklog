import Foundation
import Testing
@testable import TracklogCore

@Suite("HUD confirmations and silence")
@MainActor
struct HUDConfirmationTests: CaptureTestHelpers {
    @Test func pauseAndResumeConfirmOnlyExplicitActions() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let clock = FakeClock(base)
        let probe = HUDProbe()
        let runtime = makeHUDRuntime(
            store: store,
            clock: clock,
            probe: probe,
            adapters: [],
            credentials: MemoryCredentialStore(),
        )
        await runtime.start()

        runtime.pause(for: 60 * 60)
        let paused = try #require(probe.presentations.last)
        #expect(paused.id == "hud.confirm.pause")
        #expect(paused.duration == 2)
        #expect(paused.priority == .high)
        #expect(paused.spoken == "Scrobbling paused for 1 hour.")

        clock.advance(to: base.addingTimeInterval(60 * 60 + 1))
        await eventually { runtime.state.pausedUntil == nil }
        #expect(probe.presentations.count == 1, "an automatic resume is silent")

        runtime.pause(until: base.addingTimeInterval(4 * 60 * 60))
        runtime.resume()
        let resumed = try #require(probe.presentations.last)
        #expect(resumed.id == "hud.confirm.resume")
        #expect(resumed.spoken == "Scrobbling resumed.")
    }

    @Test func blockConfirmationUsesTheBlockedTitle() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let clock = FakeClock(base)
        let probe = HUDProbe()
        let runtime = makeHUDRuntime(
            store: store,
            clock: clock,
            probe: probe,
            adapters: [],
            credentials: MemoryCredentialStore(),
        )
        await runtime.start()

        _ = try await runtime.saveBlock(
            BlockRule(
                track: "Heart of Glass",
                artist: "Blondie",
                savedAt: base,
            ),
        )

        let blocked = try #require(probe.presentations.last)
        #expect(blocked.id == "hud.confirm.block")
        #expect(blocked.spoken == "Blocked Heart of Glass. It will not scrobble again.")
    }

    @Test func ourNewerHUDReplacesTheActiveOneAcrossPriorities() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let clock = FakeClock(base)
        let probe = HUDProbe()
        let runtime = makeHUDRuntime(
            store: store,
            clock: clock,
            probe: probe,
            adapters: [],
            credentials: MemoryCredentialStore(),
        )
        await runtime.start()

        runtime.pause(for: 60 * 60)
        _ = try await runtime.saveBlock(BlockRule(track: "Heart of Glass", savedAt: base))

        #expect(probe.host.dismissals == ["hud.confirm.pause"])
        #expect(probe.session.activeID == "hud.confirm.block")
        #expect(probe.announcements.count == 2)
    }

    @Test func refusedPresentationsAreLoggedOnceAndNeverQueued() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let clock = FakeClock(base)
        let probe = HUDProbe(accepted: false)
        let runtime = makeHUDRuntime(
            store: store,
            clock: clock,
            probe: probe,
            adapters: [],
            credentials: MemoryCredentialStore(),
        )
        await runtime.start()

        runtime.pause(for: 60 * 60)
        #expect(probe.host.presented.count == 1)
        #expect(probe.refusals.count == 1)
        #expect(probe.announcements.isEmpty)

        clock.advance(to: base.addingTimeInterval(60 * 60 + 1))
        await eventually { runtime.state.pausedUntil == nil }
        #expect(probe.host.presented.count == 1, "a refused HUD is never retried")

        _ = try await runtime.saveBlock(BlockRule(track: "Heart of Glass", savedAt: base))
        #expect(probe.host.presented.count == 2, "a later event is a new attempt, not a replay")
        #expect(probe.refusals.count == 2)
        #expect(probe.announcements.isEmpty)
        #expect(probe.session.activeID == nil)
    }

    @Test func successfulScrobblesNowPlayingAndRetriesStaySilent() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let credentials = MemoryCredentialStore()
        let clock = FakeClock(base)
        let probe = HUDProbe()
        let adapter = RecordingDeliveryAdapter(kind: .listenBrainz)
        _ = try await saveHUDConnection(
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

        let song = track()
        await runtime.ingest(sample(song, at: 0, elapsed: 0))
        #expect(probe.presentations.isEmpty, "now playing is silent")

        await replay(thresholdSamples(song), on: runtime, clock: clock)
        await eventually { runtime.state.listenCount == 1 }
        let listen = try #require(try await store.recent(limit: 1).first)
        _ = await awaitDeliveries(store, listen: listen) { $0.allSatisfy { $0.state == .delivered } }

        #expect(probe.presentations.isEmpty, "a successful scrobble and ordinary drain are silent")
    }

    @Test func retrySchedulingCancelAndEditStaySilent() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let credentials = MemoryCredentialStore()
        let clock = FakeClock(base)
        let probe = HUDProbe()
        let adapter = RecordingDeliveryAdapter(
            kind: .listenBrainz,
            answers: [.failure(.retryable)],
        )
        _ = try await saveHUDConnection(
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

        let cancelledTrack = track(title: "Cancelled")
        await runtime.ingest(sample(cancelledTrack, at: 0, elapsed: 0))
        #expect(runtime.cancelCurrentListen())
        _ = try await runtime.saveSimpleEdit(
            simpleEditRule(match: .init(artist: "Artist"), replace: .init(album: "Edited")),
        )

        await replay(thresholdSamples(track(title: "Retrying")), on: runtime, clock: clock)
        await eventually { runtime.state.listenCount == 1 }
        let listen = try #require(try await store.recent(limit: 1).first)
        let deliveries = await awaitDeliveries(store, listen: listen) {
            $0.allSatisfy { $0.state == .retrying }
        }
        #expect(deliveries.map(\.state) == [.retrying])
        #expect(probe.presentations.isEmpty, "retry scheduling, cancel and edit are silent")
    }
}
