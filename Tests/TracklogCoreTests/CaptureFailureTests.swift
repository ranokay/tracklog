import Foundation
import Testing
@testable import TracklogCore

@Suite("Capture failures")
@MainActor
struct CaptureFailureTests: CaptureTestHelpers {
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

    @Test func aFailedInsertIsVisibleAndNeverLooksDelivered() async throws {
        let clock = FakeClock(base)
        let source = ReplayedNowPlaying()
        let runtime = CaptureRuntime(
            clock: clock,
            source: source,
            store: FailingStore(),
            scrobblingEnabled: true,
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
}

private actor FailingStore: ListenStore {
    func insert(_: Listen) async throws -> Listen? {
        throw DatabaseError.sqlite("disk full")
    }

    func recent(limit _: Int) async throws -> [Listen] {
        []
    }
}
