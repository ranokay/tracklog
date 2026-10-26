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

    @Test func aHistoryReadFailureUsesTheHistoryStage() async throws {
        let clock = FakeClock(base)
        let source = ReplayedNowPlaying()
        let runtime = CaptureRuntime(
            clock: clock,
            source: source,
            store: HistoryReadFailingStore(failsAtCall: 1),
            scrobblingEnabled: true,
        )
        await runtime.start()

        let failure = try #require(runtime.state.failure)
        #expect(failure.stage == .history)
        #expect(failure.diagnostics.contains("read failed"))
        #expect(failure.message.contains("load"))
        #expect(runtime.state.historyFailure != nil)
        #expect(runtime.state.captureAvailable)
    }

    @Test func aFailedHistoryRefreshIsNotAWriteFailure() async throws {
        let clock = FakeClock(base)
        let source = ReplayedNowPlaying()
        let runtime = CaptureRuntime(
            clock: clock,
            source: source,
            store: HistoryReadFailingStore(failsAtCall: 3),
            scrobblingEnabled: true,
        )
        await runtime.start()

        await replay(thresholdSamples(track()), on: runtime, clock: clock)

        let failure = try #require(runtime.state.failure)
        #expect(failure.stage == .history)
        #expect(runtime.state.historyFailure != nil)
        #expect(runtime.state.listenCount == 1, "the listen itself was stored")
        #expect(runtime.state.lastListen != nil)
    }

    @Test func stoppingDuringAnInsertDoesNotPublishAfterTeardown() async {
        let clock = FakeClock(base)
        let source = ReplayedNowPlaying()
        let store = SuspendingStore()
        let runtime = CaptureRuntime(
            clock: clock,
            source: source,
            store: store,
            scrobblingEnabled: true,
        )
        await runtime.start()

        let ingest = Task {
            await replay(thresholdSamples(track()), on: runtime, clock: clock)
        }
        while await store.insertStarted == false {
            await Task.yield()
        }

        runtime.stop()
        await store.releaseInsert()
        await ingest.value

        #expect(runtime.state.listenCount == 0)
        #expect(runtime.state.lastListen == nil)
        #expect(runtime.state.listens.isEmpty)
    }

    @Test func disablingCaptureDuringAnInsertPreventsPublishing() async {
        let clock = FakeClock(base)
        let source = ReplayedNowPlaying()
        let store = SuspendingStore()
        let runtime = CaptureRuntime(
            clock: clock,
            source: source,
            store: store,
            scrobblingEnabled: true,
        )
        await runtime.start()

        let ingest = Task {
            await replay(thresholdSamples(track()), on: runtime, clock: clock)
        }
        while await store.insertStarted == false {
            await Task.yield()
        }

        runtime.setScrobblingEnabled(false)
        await store.releaseInsert()
        await ingest.value

        #expect(runtime.state.listenCount == 0)
        #expect(runtime.state.lastListen == nil)
        #expect(runtime.state.listens.isEmpty)
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

    func page(limit _: Int, before _: ListenCursor?) async throws -> [Listen] {
        []
    }

    func count() async throws -> Int {
        0
    }
}

private actor HistoryReadFailingStore: ListenStore {
    private let failsAtCall: Int
    private var recentCalls = 0

    init(failsAtCall: Int) {
        self.failsAtCall = failsAtCall
    }

    func insert(_ listen: Listen) async throws -> Listen? {
        listen.stored(withID: 1)
    }

    func page(limit _: Int, before _: ListenCursor?) async throws -> [Listen] {
        recentCalls += 1
        guard recentCalls != failsAtCall else {
            throw DatabaseError.sqlite("read failed")
        }
        return []
    }

    func count() async throws -> Int {
        recentCalls += 1
        guard recentCalls != failsAtCall else {
            throw DatabaseError.sqlite("read failed")
        }
        return 0
    }
}

private actor SuspendingStore: ListenStore {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var insertStarted = false

    func insert(_ listen: Listen) async throws -> Listen? {
        insertStarted = true
        await withCheckedContinuation { continuation = $0 }
        return listen.stored(withID: 1)
    }

    func page(limit _: Int, before _: ListenCursor?) async throws -> [Listen] {
        []
    }

    func count() async throws -> Int {
        0
    }

    func releaseInsert() {
        continuation?.resume()
        continuation = nil
    }
}
