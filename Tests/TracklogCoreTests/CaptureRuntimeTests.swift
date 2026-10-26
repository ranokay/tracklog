import Foundation
import Testing
@testable import TracklogCore

@Suite("Capture runtime")
@MainActor
struct CaptureRuntimeTests {
    private let base = Date(timeIntervalSince1970: 1_000_000)

    private func track(
        title: String = "Song",
        artist: String = "Artist",
        album: String = "Album",
        albumArtist: String = "Album Artist",
        duration: TimeInterval = 30,
        bundleID: String = "com.apple.Music"
    ) -> Track {
        Track(
            title: title,
            artist: artist,
            album: album,
            albumArtist: albumArtist,
            duration: duration,
            bundleID: bundleID
        )
    }

    private func sample(
        _ track: Track,
        at offset: TimeInterval,
        elapsed: TimeInterval,
        playing: Bool = true
    ) -> MediaSample {
        MediaSample(
            track: track,
            elapsed: elapsed,
            playbackRate: playing ? 1 : 0,
            isPlaying: playing,
            timestamp: base.addingTimeInterval(offset)
        )
    }

    /// Thirty seconds of two-second samples: enough for the engine's threshold
    /// on a 30-second track, with the reconstructed start at `base`.
    private func thresholdSamples(_ track: Track, offset: TimeInterval = 0) -> [MediaSample] {
        stride(from: 0.0, through: 30.0, by: 2.0).map { second in
            sample(track, at: offset + second, elapsed: second)
        }
    }

    private func runtime(
        database: TemporaryDatabase,
        clock: FakeClock,
        source: ReplayedNowPlaying,
        enabled: Bool = true,
        persistScrobbling: (@MainActor (Bool) -> Void)? = nil
    ) -> CaptureRuntime {
        CaptureRuntime.open(
            databaseURL: database.url,
            clock: clock,
            source: source,
            scrobblingEnabled: enabled,
            persistScrobbling: persistScrobbling
        )
    }

    private func replay(
        _ samples: [MediaSample],
        on runtime: CaptureRuntime,
        clock: FakeClock
    ) async {
        for sample in samples {
            clock.now = sample.timestamp
            await runtime.ingest(sample)
        }
    }

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
            albumArtist: " Album Artist "
        )
        await replay(thresholdSamples(rawTrack), on: runtime, clock: clock)

        #expect(source.startCount == 1)
        #expect(runtime.state.listens.count == 1)
        let listen = try #require(runtime.state.listens.first)
        #expect(listen.raw == ListenMetadata(
            title: "  Song ",
            artist: " Artist ",
            album: " Album ",
            albumArtist: " Album Artist "
        ))
        #expect(listen.processed == ListenMetadata(
            title: "Song",
            artist: "Artist",
            album: "Album",
            albumArtist: "Album Artist"
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

    @Test func masterSwitchOffReadsNoFeedAndStoresNothing() async throws {
        let database = try TemporaryDatabase()
        let clock = FakeClock(base)
        let source = ReplayedNowPlaying()
        var persisted: [Bool] = []
        let runtime = runtime(
            database: database,
            clock: clock,
            source: source,
            enabled: false,
            persistScrobbling: { persisted.append($0) }
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

    @Test func aDatabaseThatCannotOpenDisablesCaptureWithDiagnostics() async throws {
        let database = try TemporaryDatabase()
        let garbage = Data("this is not a database".utf8)
        try database.write(garbage)
        let clock = FakeClock(base)
        let source = ReplayedNowPlaying()
        let runtime = runtime(database: database, clock: clock, source: source)
        await runtime.start()

        #expect(runtime.state.captureAvailable == false)
        let failure = try #require(runtime.state.failure)
        #expect(failure.stage == .database)
        #expect(failure.diagnostics.contains(database.url.path))
        #expect(source.startCount == 0)

        await replay(thresholdSamples(track()), on: runtime, clock: clock)
        #expect(runtime.state.listens.isEmpty)
        #expect(try database.readData() == garbage)
    }

    @Test func aNewerSchemaRefusesToOpenAndDisablesCapture() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        await store.close()
        try database.setUserVersion(99)
        let clock = FakeClock(base)
        let source = ReplayedNowPlaying()
        let runtime = runtime(database: database, clock: clock, source: source)
        await runtime.start()

        #expect(runtime.state.captureAvailable == false)
        let failure = try #require(runtime.state.failure)
        #expect(failure.stage == .database)
        #expect(failure.diagnostics.contains("99"))
        #expect(source.startCount == 0)
        #expect(try database.userVersion() == 99)
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
            scrobblingEnabled: true
        )
        await runtime.start()

        await replay(thresholdSamples(track()), on: runtime, clock: clock)

        #expect(runtime.state === shared)
        #expect(shared.listens.count == 1)
        #expect(shared.listenCount == 1)
    }

    @Test func aFailedInsertIsVisibleAndNeverLooksDelivered() async throws {
        let clock = FakeClock(base)
        let source = ReplayedNowPlaying()
        let runtime = CaptureRuntime(
            clock: clock,
            source: source,
            store: FailingStore(),
            scrobblingEnabled: true
        )
        await runtime.start()

        await replay(thresholdSamples(track()), on: runtime, clock: clock)

        let failure = try #require(runtime.state.failure)
        #expect(failure.stage == .storage)
        #expect(failure.diagnostics.contains("disk full"))
        #expect(runtime.state.listens.isEmpty)
        #expect(runtime.state.listenCount == 0)
        #expect(runtime.state.lastListen == nil)
        #expect(runtime.state.captureAvailable)
    }

    @Test func aListenWithoutAnArtistIsNotStored() async throws {
        let database = try TemporaryDatabase()
        let clock = FakeClock(base)
        let source = ReplayedNowPlaying()
        let runtime = runtime(database: database, clock: clock, source: source)
        await runtime.start()

        await replay(thresholdSamples(track(artist: "   ")), on: runtime, clock: clock)

        #expect(runtime.state.listens.isEmpty)
        #expect(runtime.state.failure == nil)
        #expect(runtime.state.listenCount == 0)
        #expect(runtime.state.nowPlaying == nil)
        #expect(runtime.state.status == .idle)
    }

    @Test func pausedSamplesNeverCapture() async throws {
        let database = try TemporaryDatabase()
        let clock = FakeClock(base)
        let source = ReplayedNowPlaying()
        let runtime = runtime(database: database, clock: clock, source: source)
        await runtime.start()

        let track = track()
        for second in stride(from: 0.0, through: 30.0, by: 2.0) {
            clock.now = base.addingTimeInterval(second)
            await runtime.ingest(sample(track, at: second, elapsed: 0, playing: false))
        }

        #expect(runtime.state.listens.isEmpty)
        #expect(runtime.state.status.isPlaying == false)
    }

    private func listen(title: String, start: TimeInterval) -> Listen {
        Listen(
            raw: ListenMetadata(title: title, artist: "Artist"),
            processed: ListenMetadata(title: title, artist: "Artist"),
            bundleID: "com.apple.Music",
            duration: 200,
            playedDuration: 100,
            startedAt: base.addingTimeInterval(start),
            capturedAt: base.addingTimeInterval(start)
        )
    }
}

private actor FailingStore: ListenStore {
    func insert(_ listen: Listen) async throws -> Listen? {
        throw DatabaseError.sqlite("disk full")
    }

    func recent(limit: Int) async throws -> [Listen] {
        []
    }
}
