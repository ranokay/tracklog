import Foundation
import Testing
@testable import TracklogCore

@Suite("Capture controls")
@MainActor
struct CaptureControlsTests: CaptureTestHelpers {
    @Test func theDefaultMinimumDurationIsThirtySeconds() {
        #expect(CaptureSettings().minimumDuration == 30)
    }

    @Test func minimumDurationChangesTheEngineThresholdFloor() async throws {
        let database = try TemporaryDatabase()
        let clock = FakeClock(base)
        var persisted: [CaptureSettings] = []
        let runtime = runtime(
            database: database,
            clock: clock,
            source: ReplayedNowPlaying(),
            settings: CaptureSettings(scrobblingEnabled: true, minimumDuration: 120),
            persistSettings: { persisted.append($0) },
        )
        await runtime.start()
        let short = track(duration: 10)

        await runtime.ingest(sample(short, at: 0, elapsed: 0))
        #expect(abs(runtime.state.status.target - 119.4) < 0.001)

        runtime.setMinimumDuration(60)
        #expect(runtime.state.minimumDuration == 60)
        #expect(persisted.last?.minimumDuration == 60)

        await runtime.ingest(sample(short, at: 2, elapsed: 2))
        #expect(abs(runtime.state.status.target - 59.4) < 0.001)
    }

    @Test func minimumDurationIsClampedToThirtyThroughThreeHundred() async throws {
        #expect(CaptureSettings(minimumDuration: 5).minimumDuration == 30)
        #expect(CaptureSettings(minimumDuration: 1_000).minimumDuration == 300)

        let database = try TemporaryDatabase()
        let runtime = runtime(
            database: database,
            clock: FakeClock(base),
            source: ReplayedNowPlaying(),
            settings: CaptureSettings(scrobblingEnabled: true, minimumDuration: 5),
        )
        await runtime.start()
        #expect(runtime.state.minimumDuration == 30)

        runtime.setMinimumDuration(1_000)
        #expect(runtime.state.minimumDuration == 300)
    }

    @Test func turningNowPlayingOffKeepsCaptureRunningAndSilencesTheSendPath() async throws {
        let database = try TemporaryDatabase()
        let clock = FakeClock(base)
        var sends: [Track] = []
        var persisted: [CaptureSettings] = []
        let runtime = runtime(
            database: database,
            clock: clock,
            source: ReplayedNowPlaying(),
            settings: CaptureSettings(scrobblingEnabled: true, nowPlayingEnabled: false),
            persistSettings: { persisted.append($0) },
            sendNowPlaying: { sends.append($0) },
        )
        await runtime.start()

        await replay(thresholdSamples(track(title: "Silent")), on: runtime, clock: clock)

        #expect(sends.isEmpty)
        #expect(runtime.state.listens.count == 1, "capture is unaffected")
        #expect(runtime.state.nowPlaying?.track.title == "Silent", "the widget still sees the track")

        runtime.setNowPlayingEnabled(true)
        #expect(runtime.state.nowPlayingEnabled)
        #expect(persisted.last?.nowPlayingEnabled == true)

        await replay(thresholdSamples(track(title: "Audible"), offset: 60), on: runtime, clock: clock)

        #expect(sends.map(\.title).contains("Audible"))
        #expect(runtime.state.listens.count == 2)
    }

    @Test func unknownDurationKeepsItsFlatFloorWhenTheMinimumChanges() async throws {
        let database = try TemporaryDatabase()
        let runtime = runtime(
            database: database,
            clock: FakeClock(base),
            source: ReplayedNowPlaying(),
            settings: CaptureSettings(scrobblingEnabled: true, minimumDuration: 120),
        )
        await runtime.start()
        let unknown = track(duration: 0)

        await runtime.ingest(sample(unknown, at: 0, elapsed: 0))
        #expect(runtime.state.status.target == 30)

        runtime.setMinimumDuration(60)
        await runtime.ingest(sample(unknown, at: 2, elapsed: 2))
        #expect(runtime.state.status.target == 30)
    }

    @Test func nowPlayingSettingSurvivesRelaunch() async throws {
        let database = try TemporaryDatabase()
        var persisted: [CaptureSettings] = []
        let first = runtime(
            database: database,
            clock: FakeClock(base),
            source: ReplayedNowPlaying(),
            persistSettings: { persisted.append($0) },
        )
        await first.start()
        first.setNowPlayingEnabled(false)
        first.stop()

        guard let restored = persisted.last else {
            Issue.record("the now-playing switch was not persisted")
            return
        }
        let second = runtime(
            database: database,
            clock: FakeClock(base),
            source: ReplayedNowPlaying(),
            settings: restored,
        )
        await second.start()

        #expect(second.state.nowPlayingEnabled == false)
    }
}
