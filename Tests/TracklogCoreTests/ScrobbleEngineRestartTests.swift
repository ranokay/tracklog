import Foundation
import Testing
import TracklogCore

@Suite("Scrobble engine restart")
@MainActor
struct ScrobbleEngineRestartTests {
    private let base = Date(timeIntervalSince1970: 1_000_000)

    private func sample(
        _ track: Track,
        at offset: TimeInterval,
        elapsed: TimeInterval,
        playing: Bool = true,
        rate: Double? = nil,
    ) -> MediaSample {
        MediaSample(
            track: track,
            elapsed: elapsed,
            playbackRate: rate ?? (playing ? 1 : 0),
            isPlaying: playing,
            timestamp: base.addingTimeInterval(offset),
        )
    }

    /// A sample whose player last reported its position at `reportedAt`, the
    /// way the helper keeps a seek or resume as its timestamp, and which
    /// Tracklog read at `observedAt`.
    private func reportedSample(
        _ track: Track,
        observedAt: TimeInterval,
        reportedAt: TimeInterval,
        elapsed: TimeInterval,
        playing: Bool = true,
        rate: Double = 1,
    ) -> MediaSample {
        MediaSample(
            track: track,
            elapsed: elapsed,
            playbackRate: playing ? rate : 0,
            isPlaying: playing,
            timestamp: base.addingTimeInterval(reportedAt),
            observedAt: base.addingTimeInterval(observedAt),
        )
    }

    private func scrobble(in effects: [ScrobbleEffect]) -> Scrobble? {
        for effect in effects {
            if case let .scrobble(scrobble) = effect {
                return scrobble
            }
        }
        return nil
    }

    @Test func aBackwardSeekMidTrackKeepsTheSessionAndItsStart() {
        let track = Track(title: "Track", duration: 200)
        let engine = ScrobbleEngine()
        var effects: [ScrobbleEffect] = []

        for second in stride(from: 0.0, through: 60.0, by: 2.0) {
            effects = engine.ingest(sample(track, at: second, elapsed: second))
        }
        #expect(effects.isEmpty)

        // At 1:00 the listener rewinds to 0:15; the observation lands five
        // seconds after the seek. The report position is 15, so this is a
        // seek, not a restart.
        effects = engine.ingest(reportedSample(track, observedAt: 65, reportedAt: 60, elapsed: 20))
        #expect(effects.isEmpty)
        #expect(abs(engine.status.played - 65) < 0.001, "the session keeps its played time and adds the gap")

        var all = effects
        for second in stride(from: 67.0, through: 101.0, by: 2.0) {
            all += engine.ingest(sample(track, at: second, elapsed: second - 45))
        }
        #expect(scrobble(in: all)?.playedAt == base, "the seek keeps the original start")
    }

    @Test func aPlainPauseAndResumeAtTheSamePositionIsNotARestart() {
        let track = Track(title: "Track", duration: 60)
        let engine = ScrobbleEngine()
        var effects: [ScrobbleEffect] = []

        for second in stride(from: 0.0, through: 10.0, by: 2.0) {
            effects = engine.ingest(sample(track, at: second, elapsed: second))
        }
        effects = engine.ingest(sample(track, at: 11, elapsed: 10, playing: false))
        #expect(effects.isEmpty)
        #expect(abs(engine.status.played - 10) < 0.001)

        // The player resumes at the same position and reports the resume.
        effects = engine.ingest(reportedSample(track, observedAt: 12, reportedAt: 11.8, elapsed: 10.2))
        #expect(effects.isEmpty)
        #expect(engine.status.played > 10, "the resume continues the session")

        var all = effects
        for second in stride(from: 14.0, through: 40.0, by: 2.0) {
            all += engine.ingest(sample(track, at: second, elapsed: 12.2 + (second - 14.0)))
        }
        #expect(scrobble(in: all)?.playedAt == base, "the resume keeps the original start")
    }

    @Test func aSeekToTheStartSeenWhilePausedReplacesOnlyOnResume() {
        let track = Track(title: "Track", duration: 200)
        let engine = ScrobbleEngine()
        var effects: [ScrobbleEffect] = []

        for second in stride(from: 0.0, through: 60.0, by: 2.0) {
            effects = engine.ingest(sample(track, at: second, elapsed: second))
        }
        effects = engine.ingest(sample(track, at: 61, elapsed: 60, playing: false))
        #expect(effects.isEmpty)
        #expect(abs(engine.status.played - 60) < 0.001)

        // The seek to 0:00 is seen while the player is paused. It must not
        // replace the session or reset its played time yet.
        effects = engine.ingest(reportedSample(track, observedAt: 65, reportedAt: 64, elapsed: 0, playing: false))
        #expect(effects.isEmpty)
        #expect(abs(engine.status.played - 60) < 0.001, "a paused seek does not reset the session")

        // Playback resumes at 0:00.2. The restart starts now, from the
        // resume's report time.
        effects = engine.ingest(reportedSample(track, observedAt: 66, reportedAt: 65.8, elapsed: 0.2))
        #expect(abs(engine.status.played - 0.2) < 0.001, "the new session starts at the resume")

        var all = effects
        for second in stride(from: 68.0, through: 180.0, by: 2.0) {
            all += engine.ingest(sample(track, at: second, elapsed: 2.2 + (second - 68.0)))
        }
        #expect(
            scrobble(in: all)?.playedAt == base.addingTimeInterval(65.8),
            "the new listen starts when playback resumed, not when the seek was seen",
        )
    }
}
