import Foundation
import Testing
@testable import TracklogCore

@Suite("Capture pause")
@MainActor
struct CapturePauseTests: CaptureTestHelpers {
    @Test func pausingStopsTheFeedDiscardsTheSessionAndPersistsTheEnd() async throws {
        let database = try TemporaryDatabase()
        let clock = FakeClock(base)
        let source = ReplayedNowPlaying()
        var persisted: [CaptureSettings] = []
        let runtime = runtime(
            database: database,
            clock: clock,
            source: source,
            persistSettings: { persisted.append($0) },
        )
        await runtime.start()

        // Arm a session that has not reached the threshold.
        await replay(Array(thresholdSamples(track()).prefix(4)), on: runtime, clock: clock)
        #expect(runtime.state.nowPlaying != nil)
        #expect(runtime.state.status.phase == .armed)

        let until = base.addingTimeInterval(3600)
        runtime.pause(until: until)

        #expect(runtime.state.pausedUntil == until)
        #expect(source.stopCount == 1)
        #expect(runtime.state.nowPlaying == nil)
        #expect(runtime.state.status == .idle)
        #expect(persisted.last?.pausedUntil == until)

        await replay(thresholdSamples(track(), offset: 60), on: runtime, clock: clock)

        #expect(runtime.state.listens.isEmpty)
        #expect(runtime.state.nowPlaying == nil)
        #expect(runtime.state.listenCount == 0)
    }

    @Test func aManualResumeClearsThePauseAndRestartsTheFeed() async throws {
        let database = try TemporaryDatabase()
        let clock = FakeClock(base)
        let source = ReplayedNowPlaying()
        var persisted: [CaptureSettings] = []
        let runtime = runtime(
            database: database,
            clock: clock,
            source: source,
            persistSettings: { persisted.append($0) },
        )
        await runtime.start()
        runtime.pause(until: base.addingTimeInterval(3600))

        runtime.resume()

        #expect(runtime.state.pausedUntil == nil)
        #expect(source.startCount == 2)
        #expect(persisted.last?.pausedUntil == nil)

        await replay(thresholdSamples(track(), offset: 60), on: runtime, clock: clock)
        #expect(runtime.state.listens.count == 1)
    }

    @Test func aPauseExpiresOnScheduleAndRestartsCapture() async throws {
        let database = try TemporaryDatabase()
        let clock = FakeClock(base)
        let source = ReplayedNowPlaying()
        var persisted: [CaptureSettings] = []
        let runtime = runtime(
            database: database,
            clock: clock,
            source: source,
            persistSettings: { persisted.append($0) },
        )
        await runtime.start()

        runtime.pause(for: 3600)
        #expect(runtime.state.pausedUntil == base.addingTimeInterval(3600))
        #expect(source.stopCount == 1)
        #expect(source.startCount == 1)

        clock.advance(to: base.addingTimeInterval(3600))
        await yieldUntil { runtime.state.pausedUntil == nil }

        #expect(runtime.state.pausedUntil == nil)
        #expect(source.startCount == 2, "capture restarts without a manual resume")
        #expect(persisted.last?.pausedUntil == nil)

        await replay(thresholdSamples(track(), offset: 60), on: runtime, clock: clock)
        #expect(runtime.state.listens.count == 1)
    }

    @Test func anExpiredPauseIsClearedOnActivation() async throws {
        let database = try TemporaryDatabase()
        let clock = FakeClock(base)
        let source = ReplayedNowPlaying()
        let until = base.addingTimeInterval(-60)
        var persisted: [CaptureSettings] = []
        let runtime = runtime(
            database: database,
            clock: clock,
            source: source,
            settings: CaptureSettings(scrobblingEnabled: true, pausedUntil: until),
            persistSettings: { persisted.append($0) },
        )
        #expect(runtime.state.pausedUntil == until)

        await runtime.start()

        #expect(runtime.state.pausedUntil == nil)
        #expect(source.startCount == 1)
        #expect(persisted.last?.pausedUntil == nil)
    }

    @Test func aFuturePauseSurvivesRelaunchAndRestartsAtItsEnd() async throws {
        let database = try TemporaryDatabase()
        let until = base.addingTimeInterval(3600)
        var persisted: [CaptureSettings] = []

        let first = runtime(
            database: database,
            clock: FakeClock(base),
            source: ReplayedNowPlaying(),
            persistSettings: { persisted.append($0) },
        )
        await first.start()
        first.pause(until: until)
        first.stop()

        let clock = FakeClock(base)
        let source = ReplayedNowPlaying()
        guard let restored = persisted.last else {
            Issue.record("the pause was not persisted")
            return
        }
        let second = runtime(
            database: database,
            clock: clock,
            source: source,
            settings: restored,
        )
        await second.start()

        #expect(second.state.pausedUntil == until)
        #expect(source.startCount == 0, "a pause still in force keeps the feed down")

        clock.advance(to: until)
        await yieldUntil { second.state.pausedUntil == nil }

        #expect(source.startCount == 1)
    }

    @Test func turningScrobblingOnWhilePausedDoesNotStartTheFeed() async throws {
        let database = try TemporaryDatabase()
        let clock = FakeClock(base)
        let source = ReplayedNowPlaying()
        let runtime = runtime(database: database, clock: clock, source: source)
        await runtime.start()
        runtime.pause(for: 3600)

        runtime.setScrobblingEnabled(false)
        runtime.setScrobblingEnabled(true)

        #expect(runtime.state.pausedUntil != nil)
        #expect(source.startCount == 1)
    }

    /// There is no outbox yet, so the durable record is the proof that a
    /// captured listen survives the switch.
    @Test func switchOffStopsCaptureWithoutDiscardingStoredListens() async throws {
        let database = try TemporaryDatabase()
        let clock = FakeClock(base)
        let source = ReplayedNowPlaying()
        let runtime = runtime(database: database, clock: clock, source: source)
        await runtime.start()

        await replay(thresholdSamples(track()), on: runtime, clock: clock)
        #expect(runtime.state.listens.count == 1)

        runtime.setScrobblingEnabled(false)

        #expect(source.stopCount == 1)
        #expect(runtime.state.nowPlaying == nil)
        #expect(runtime.state.listens.count == 1)
        #expect(runtime.state.listenCount == 1)

        let store = try SQLiteListenStore(url: database.url)
        #expect(try await store.count() == 1)
        #expect(try await store.recent(limit: 10).first?.processed.title == "Song")
    }

    /// The allowlist read for a first-seen player suspends; a pause that lands
    /// during it must not be undone when the read returns.
    @Test func aPauseDuringTheAllowlistReadDoesNotRearmTheEngine() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let allowlist = SuspendedAppAllowlist()
        let runtime = CaptureRuntime(
            clock: FakeClock(base),
            source: ReplayedNowPlaying(),
            store: store,
            allowlist: allowlist,
            settings: CaptureSettings(scrobblingEnabled: true),
        )
        await runtime.start()

        let ingest = Task {
            await runtime.ingest(sample(track(bundleID: "com.example.Video"), at: 0, elapsed: 0))
        }
        while await allowlist.recordStarted == false {
            await Task.yield()
        }

        runtime.pause(for: 3600)
        await allowlist.releaseRecord()
        await ingest.value

        #expect(runtime.state.pausedUntil != nil)
        #expect(runtime.state.nowPlaying == nil)
        #expect(runtime.state.status == .idle)
        runtime.stop()
    }

    @Test func switchingOffDuringTheAllowlistReadDoesNotRearmTheEngine() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let allowlist = SuspendedAppAllowlist()
        let runtime = CaptureRuntime(
            clock: FakeClock(base),
            source: ReplayedNowPlaying(),
            store: store,
            allowlist: allowlist,
            settings: CaptureSettings(scrobblingEnabled: true),
        )
        await runtime.start()

        let ingest = Task {
            await runtime.ingest(sample(track(bundleID: "com.example.Video"), at: 0, elapsed: 0))
        }
        while await allowlist.recordStarted == false {
            await Task.yield()
        }

        runtime.setScrobblingEnabled(false)
        await allowlist.releaseRecord()
        await ingest.value

        #expect(runtime.state.scrobblingEnabled == false)
        #expect(runtime.state.nowPlaying == nil)
        #expect(runtime.state.status == .idle)
        runtime.stop()
    }
}

/// An allowlist whose first `recordSeen` suspends, so a test can land a pause
/// or a switch-off between the gate check and the engine.
private actor SuspendedAppAllowlist: AppAllowlistStore {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var recordStarted = false

    func apps() async throws -> [SeenApp] {
        [SeenApp(bundleID: "com.apple.Music", isAllowed: true)]
    }

    func isAllowed(_ bundleID: String) async throws -> Bool {
        bundleID == "com.apple.Music"
    }

    @discardableResult
    func recordSeen(_ bundleID: String) async throws -> SeenApp? {
        recordStarted = true
        await withCheckedContinuation { continuation = $0 }
        return SeenApp(bundleID: bundleID, isAllowed: true)
    }

    func setAllowed(_: String, allowed _: Bool) async throws {}

    func releaseRecord() {
        continuation?.resume()
        continuation = nil
    }
}
