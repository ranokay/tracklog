import Foundation
import Testing
@testable import TracklogCore

/// The real capture path for a seek back to the start: the app state, the
/// runtime and SQLite history, with only the clock and feed scripted.
@Suite("Capture seek restart")
@MainActor
struct CaptureSeekTests: CaptureTestHelpers {
    private func sample(
        _ track: Track,
        elapsed: TimeInterval,
        playing: Bool,
        reportedAt: Date,
        observedAt: Date,
    ) -> MediaSample {
        MediaSample(
            track: track,
            elapsed: elapsed,
            playbackRate: playing ? 1 : 0,
            isPlaying: playing,
            timestamp: reportedAt,
            observedAt: observedAt,
        )
    }

    @Test func aSeekBackToTheStartAfterAPausedLaunchUsesThePlayTime() async throws {
        let database = try TemporaryDatabase()
        let clock = FakeClock(base)
        let source = ReplayedNowPlaying()
        let runtime = runtime(database: database, clock: clock, source: source)
        await runtime.start()

        let track = track(duration: 200)
        let playTime = base.addingTimeInterval(57)

        // The host launched with the track paused at 1:41.
        clock.now = base
        await runtime.ingest(sample(
            track,
            elapsed: 101,
            playing: false,
            reportedAt: base,
            observedAt: base,
        ))
        #expect(runtime.state.listens.isEmpty)

        // The seek to 0:00 and the play that follows are first observed four
        // seconds in, the paused poll's cadence. The player's report is the
        // play time.
        clock.now = playTime.addingTimeInterval(4)
        await runtime.ingest(sample(
            track,
            elapsed: 4,
            playing: true,
            reportedAt: playTime,
            observedAt: playTime.addingTimeInterval(4),
        ))
        #expect(runtime.state.listens.isEmpty, "the replaced paused session was below the threshold")

        for second in stride(from: 6.0, through: 104.0, by: 2.0) {
            clock.now = playTime.addingTimeInterval(second)
            await runtime.ingest(sample(
                track,
                elapsed: second,
                playing: true,
                reportedAt: playTime,
                observedAt: playTime.addingTimeInterval(second),
            ))
        }

        #expect(runtime.state.listens.count == 1)
        let listen = try #require(runtime.state.listens.first)
        #expect(listen.startedAt == playTime, "the listen starts when playback resumed, not at launch minus the pause")

        let reopened = try SQLiteListenStore(url: database.url)
        let stored = try #require(try await reopened.recent(limit: 10).first)
        #expect(stored.startedAt == playTime)
    }

    @Test func aReplacedSessionThatAlreadyMetTheThresholdKeepsItsListen() async throws {
        let database = try TemporaryDatabase()
        let clock = FakeClock(base)
        let source = ReplayedNowPlaying()
        let runtime = runtime(database: database, clock: clock, source: source)
        await runtime.start()

        let track = track(duration: 200)
        for second in stride(from: 0.0, through: 100.0, by: 2.0) {
            clock.now = base.addingTimeInterval(second)
            await runtime.ingest(sample(
                track,
                elapsed: second,
                playing: true,
                reportedAt: base.addingTimeInterval(second),
                observedAt: base.addingTimeInterval(second),
            ))
        }
        #expect(runtime.state.listens.count == 1)
        #expect(runtime.state.listens.first?.startedAt == base)

        let secondPlay = base.addingTimeInterval(120)
        for second in stride(from: 0.0, through: 100.0, by: 2.0) {
            clock.now = secondPlay.addingTimeInterval(second)
            await runtime.ingest(sample(
                track,
                elapsed: second,
                playing: true,
                reportedAt: secondPlay,
                observedAt: secondPlay.addingTimeInterval(second),
            ))
        }

        #expect(runtime.state.listens.count == 2)
        #expect(runtime.state.listens.first?.startedAt == secondPlay)
        #expect(runtime.state.listens.last?.startedAt == base, "the replaced session keeps its listen")
    }
}
