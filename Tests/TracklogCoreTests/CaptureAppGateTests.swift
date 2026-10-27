import Foundation
import Testing
@testable import TracklogCore

@Suite("Capture app gate")
@MainActor
struct CaptureAppGateTests: CaptureTestHelpers {
    @Test func aNewDatabaseShowsMusicAndSpotifyAsAllowed() async throws {
        let database = try TemporaryDatabase()
        let runtime = runtime(database: database, clock: FakeClock(base), source: ReplayedNowPlaying())
        await runtime.start()

        #expect(runtime.state.seenApps.map(\.bundleID) == ["com.apple.Music", "com.spotify.client"])
        #expect(runtime.state.seenApps.map(\.isAllowed) == [true, true])
    }

    @Test func aDeniedAppProducesNoNowPlayingOrHistoryButIsListed() async throws {
        let database = try TemporaryDatabase()
        let clock = FakeClock(base)
        let runtime = runtime(database: database, clock: clock, source: ReplayedNowPlaying())
        await runtime.start()

        let denied = track(title: "Video", bundleID: "com.example.Video")
        await replay(thresholdSamples(denied), on: runtime, clock: clock)

        #expect(runtime.state.nowPlaying == nil)
        #expect(runtime.state.listens.isEmpty)
        #expect(runtime.state.listenCount == 0)
        #expect(runtime.state.seenApps.last?.bundleID == "com.example.Video")
        #expect(runtime.state.seenApps.last?.isAllowed == false)
        #expect(try await runtime.store?.count() == 0)
    }

    @Test func anEmptyBundleIDIsDeniedAndNeverListed() async throws {
        let database = try TemporaryDatabase()
        let clock = FakeClock(base)
        let runtime = runtime(database: database, clock: clock, source: ReplayedNowPlaying())
        await runtime.start()

        await replay(thresholdSamples(track(bundleID: "  ")), on: runtime, clock: clock)

        #expect(runtime.state.nowPlaying == nil)
        #expect(runtime.state.listens.isEmpty)
        #expect(runtime.state.seenApps.map(\.bundleID) == ["com.apple.Music", "com.spotify.client"])
    }

    @Test func allowingAnAppTakesEffectOnItsNextSample() async throws {
        let database = try TemporaryDatabase()
        let clock = FakeClock(base)
        let runtime = runtime(database: database, clock: clock, source: ReplayedNowPlaying())
        await runtime.start()

        let denied = track(title: "Video", bundleID: "com.example.Video")
        await replay(thresholdSamples(denied), on: runtime, clock: clock)
        #expect(runtime.state.listens.isEmpty)

        await runtime.setAppAllowed("com.example.Video", allowed: true)
        #expect(runtime.state.seenApps.first { $0.bundleID == "com.example.Video" }?.isAllowed == true)

        await replay(thresholdSamples(denied, offset: 60), on: runtime, clock: clock)

        #expect(runtime.state.nowPlaying?.track.bundleID == "com.example.Video")
        #expect(runtime.state.listens.count == 1)
        #expect(runtime.state.lastListen?.bundleID == "com.example.Video")
    }

    @Test func aDenialSurvivesRelaunch() async throws {
        let database = try TemporaryDatabase()
        let first = runtime(database: database, clock: FakeClock(base), source: ReplayedNowPlaying())
        await first.start()

        await first.setAppAllowed("com.apple.Music", allowed: false)
        first.stop()

        let clock = FakeClock(base)
        let second = runtime(database: database, clock: clock, source: ReplayedNowPlaying())
        await second.start()

        #expect(second.state.seenApps.first { $0.bundleID == "com.apple.Music" }?.isAllowed == false)

        await replay(thresholdSamples(track(bundleID: "com.apple.Music")), on: second, clock: clock)

        #expect(second.state.nowPlaying == nil)
        #expect(second.state.listens.isEmpty)
    }
}
