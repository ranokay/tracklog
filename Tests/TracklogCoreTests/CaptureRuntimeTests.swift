import Foundation
import Testing
@testable import TracklogCore

@Suite("Capture runtime")
@MainActor
struct CaptureRuntimeTests: CaptureTestHelpers {
    @Test func aValidPlayingSampleCreatesExactlyOneListen() async throws {
        let database = try TemporaryDatabase()
        let clock = FakeClock(base)
        let source = ReplayedNowPlaying()
        let runtime = runtime(database: database, clock: clock, source: source)
        await runtime.start()

        let rawTrack = track(
            title: "  Song ",
            artist: " Artist ",
            album: " Album ",
            albumArtist: " Album Artist ",
        )
        await replay(thresholdSamples(rawTrack), on: runtime, clock: clock)

        #expect(source.startCount == 1)
        #expect(runtime.state.listens.count == 1)
        let listen = try #require(runtime.state.listens.first)
        #expect(listen.raw == ListenMetadata(
            title: "  Song ",
            artist: " Artist ",
            album: " Album ",
            albumArtist: " Album Artist ",
        ))
        #expect(listen.processed == ListenMetadata(
            title: "Song",
            artist: "Artist",
            album: "Album",
            albumArtist: "Album Artist",
        ))
        #expect(listen.bundleID == "com.apple.Music")
        #expect(listen.duration == 30)
        #expect(listen.playedDuration == 30)
        #expect(listen.startedAt == base)
        #expect(listen.capturedAt == base.addingTimeInterval(30))
        #expect(listen.id != nil)
        #expect(runtime.state.listenCount == 1)
        #expect(runtime.state.lastListen?.startedAt == base)
        #expect(runtime.state.nowPlaying?.track == rawTrack)
        #expect(runtime.state.failure == nil)

        let reopened = try SQLiteListenStore(url: database.url)
        #expect(try await reopened.recent(limit: 10) == [listen])
    }

    @Test func replayingTheSameListenAfterAReloadInsertsNothing() async throws {
        let database = try TemporaryDatabase()
        let track = track()
        let samples = thresholdSamples(track)

        let firstClock = FakeClock(base)
        let firstSource = ReplayedNowPlaying()
        let first = runtime(database: database, clock: firstClock, source: firstSource)
        await first.start()
        await replay(samples, on: first, clock: firstClock)
        #expect(first.state.listens.count == 1)
        first.stop()

        let secondClock = FakeClock(base)
        let secondSource = ReplayedNowPlaying()
        let second = runtime(database: database, clock: secondClock, source: secondSource)
        await second.start()
        #expect(second.state.listens.count == 1, "history survives the reload")

        await replay(samples, on: second, clock: secondClock)

        #expect(second.state.listens.count == 1)
        #expect(second.state.listenCount == 0, "a duplicate is not submitted")
        #expect(second.state.lastListen == nil)

        let store = try SQLiteListenStore(url: database.url)
        #expect(try await store.recent(limit: 10).count == 1)
    }

    @Test func switchOffReadsNoFeedAndStoresNothing() async throws {
        let database = try TemporaryDatabase()
        let clock = FakeClock(base)
        let source = ReplayedNowPlaying()
        var persisted: [Bool] = []
        let runtime = runtime(
            database: database,
            clock: clock,
            source: source,
            enabled: false,
            persistScrobbling: { persisted.append($0) },
        )
        await runtime.start()

        #expect(runtime.state.scrobblingEnabled == false)
        #expect(source.startCount == 0)
        #expect(source.handler == nil)

        let track = track()
        await replay(thresholdSamples(track), on: runtime, clock: clock)
        #expect(runtime.state.listens.isEmpty)
        #expect(runtime.state.nowPlaying == nil)

        runtime.setScrobblingEnabled(true)
        #expect(runtime.state.scrobblingEnabled)
        #expect(source.startCount == 1)
        #expect(persisted == [true])

        runtime.setScrobblingEnabled(false)
        #expect(runtime.state.scrobblingEnabled == false)
        #expect(source.stopCount == 1)
        #expect(source.handler == nil)
        #expect(runtime.state.nowPlaying == nil)
        #expect(runtime.state.status == .idle)
        #expect(persisted == [true, false])
    }

    @Test func historyIsEmptyOnFirstRun() async throws {
        let database = try TemporaryDatabase()
        let clock = FakeClock(base)
        let source = ReplayedNowPlaying()
        let runtime = runtime(database: database, clock: clock, source: source)
        await runtime.start()

        #expect(runtime.state.listens.isEmpty)
    }

    @Test func historyLoadsNewestFirst() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        _ = try await store.insert(listen(title: "Oldest", start: 100))
        _ = try await store.insert(listen(title: "Newest", start: 300))
        _ = try await store.insert(listen(title: "Middle", start: 200))
        await store.close()

        let clock = FakeClock(base)
        let source = ReplayedNowPlaying()
        let runtime = runtime(database: database, clock: clock, source: source)
        await runtime.start()

        #expect(runtime.state.listens.map(\.processed.title) == ["Newest", "Middle", "Oldest"])
    }

    @Test func capturesPublishIntoTheStateTheDropletAlreadyOwns() async throws {
        let database = try TemporaryDatabase()
        let clock = FakeClock(base)
        let source = ReplayedNowPlaying()
        let shared = TracklogAppState()
        let runtime = CaptureRuntime.open(
            state: shared,
            databaseURL: database.url,
            clock: clock,
            source: source,
            scrobblingEnabled: true,
        )
        await runtime.start()

        await replay(thresholdSamples(track()), on: runtime, clock: clock)

        #expect(runtime.state === shared)
        #expect(shared.listens.count == 1)
        #expect(shared.listenCount == 1)
    }
}
