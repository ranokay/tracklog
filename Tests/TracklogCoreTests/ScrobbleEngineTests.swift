import Foundation
import Testing
import TracklogCore

@Suite("Scrobble engine")
@MainActor
struct ScrobbleEngineTests {
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

    private func isScrobble(_ effect: ScrobbleEffect) -> Bool {
        if case .scrobble = effect {
            return true
        }
        return false
    }

    @Test func thresholdUsesPanoFormula() {
        let cases: [(duration: TimeInterval, target: TimeInterval)] = [
            (200, 100),
            (1000, 240),
            (30, 29.4),
            (10, 29.4),
            (0, 30),
        ]

        for (duration, expected) in cases {
            let engine = ScrobbleEngine()
            let track = Track(title: "Track", duration: duration)
            _ = engine.ingest(sample(track, at: 0, elapsed: 0))
            #expect(abs(engine.status.target - expected) < 0.001, "duration \(duration)")
        }
    }

    @Test func nowPlayingArrivesAfterSettle() {
        let track = Track(title: "Track", duration: 200)
        let engine = ScrobbleEngine()

        #expect(engine.ingest(sample(track, at: 0, elapsed: 0)).isEmpty)

        let effects = engine.ingest(sample(track, at: 2, elapsed: 2))
        #expect(effects == [.nowPlaying(track)])
        #expect(engine.status.phase == .armed)
    }

    @Test func pauseDoesNotAccumulatePlayedTime() {
        let track = Track(title: "Track", duration: 200)
        let engine = ScrobbleEngine()

        _ = engine.ingest(sample(track, at: 0, elapsed: 0))
        _ = engine.ingest(sample(track, at: 2, elapsed: 0, playing: false))
        #expect(engine.status.played == 0)

        _ = engine.ingest(sample(track, at: 4, elapsed: 2))
        #expect(abs(engine.status.played - 2) < 0.001)
    }

    @Test func longGapIsCappedAtOneSampleGap() {
        let track = Track(title: "Track", duration: 200)
        let engine = ScrobbleEngine()

        _ = engine.ingest(sample(track, at: 0, elapsed: 0))
        _ = engine.ingest(sample(track, at: 100, elapsed: 100))

        #expect(engine.status.played == 5)
    }

    @Test func seekForwardDoesNotAddPlayedTime() {
        let track = Track(title: "Track", duration: 200)
        let engine = ScrobbleEngine()

        _ = engine.ingest(sample(track, at: 0, elapsed: 0))
        _ = engine.ingest(sample(track, at: 2, elapsed: 120))

        #expect(abs(engine.status.played - 2) < 0.001)
        #expect(engine.status.target == 100)
    }

    @Test func restartBeginsASession() {
        let track = Track(title: "Track", duration: 200)
        let engine = ScrobbleEngine()

        _ = engine.ingest(sample(track, at: 0, elapsed: 100))
        _ = engine.ingest(sample(track, at: 2, elapsed: 101))
        _ = engine.ingest(sample(track, at: 4, elapsed: 0))

        #expect(engine.status.played == 0)
        #expect(engine.status.phase == .armed)
        #expect(engine.status.track == track)
    }

    @Test func scrobblesAtThresholdWithReconstructedStart() {
        let track = Track(title: "Track", duration: 30)
        let engine = ScrobbleEngine()
        var effects: [ScrobbleEffect] = []

        for second in stride(from: 0.0, through: 30.0, by: 2.0) {
            effects = engine.ingest(sample(track, at: second, elapsed: second))
        }

        #expect(
            effects == [
                .scrobble(
                    Scrobble(
                        track: track,
                        playedAt: base,
                        playedDuration: 30,
                    ),
                ),
            ],
        )
        #expect(engine.status.phase == .scrobbled)
    }

    @Test func midTrackFirstSampleReconstructsTheStart() {
        let track = Track(title: "Track", duration: 30)
        let engine = ScrobbleEngine()
        var effects: [ScrobbleEffect] = []

        for second in stride(from: 0.0, through: 30.0, by: 2.0) {
            effects = engine.ingest(sample(track, at: second, elapsed: 50 + second))
        }

        #expect(
            effects == [
                .scrobble(
                    Scrobble(
                        track: track,
                        playedAt: base.addingTimeInterval(-50),
                        playedDuration: 30,
                    ),
                ),
            ],
        )
    }

    @Test func duplicateWithinTheWindowIsSuppressed() {
        let engine = ScrobbleEngine(configuration: shortThresholdConfiguration())
        let track = Track(title: "Track", duration: 0)

        _ = engine.ingest(sample(track, at: 0, elapsed: 0))
        let first = engine.ingest(sample(track, at: 2, elapsed: 2))
        #expect(first.contains(where: isScrobble))

        _ = engine.ingest(sample(track, at: 3, elapsed: 10))
        _ = engine.ingest(sample(track, at: 4, elapsed: 0))
        _ = engine.ingest(sample(track, at: 5, elapsed: 1))
        let second = engine.ingest(sample(track, at: 6, elapsed: 2))

        #expect(second.isEmpty)
    }

    @Test func repeatAfterTheWindowScrobblesAgain() {
        let engine = ScrobbleEngine(configuration: shortThresholdConfiguration())
        let track = Track(title: "Track", duration: 0)

        _ = engine.ingest(sample(track, at: 0, elapsed: 0))
        _ = engine.ingest(sample(track, at: 2, elapsed: 2))
        _ = engine.ingest(sample(track, at: 3, elapsed: 10))
        _ = engine.ingest(sample(track, at: 20, elapsed: 0))
        _ = engine.ingest(sample(track, at: 21, elapsed: 1))
        let effects = engine.ingest(sample(track, at: 22, elapsed: 2))

        #expect(
            effects == [
                .scrobble(
                    Scrobble(
                        track: track,
                        playedAt: base.addingTimeInterval(20),
                        playedDuration: 2,
                    ),
                ),
            ],
        )
    }

    @Test func trackChangeFinalizesSilentlyBelowThreshold() {
        let first = Track(title: "First", duration: 200)
        let second = Track(title: "Second", duration: 200)
        let engine = ScrobbleEngine()

        _ = engine.ingest(sample(first, at: 0, elapsed: 0))
        _ = engine.ingest(sample(first, at: 2, elapsed: 2))
        let effects = engine.ingest(sample(second, at: 4, elapsed: 0))

        #expect(effects.isEmpty)
        #expect(engine.status.track == second)
        #expect(engine.status.played == 0)
    }

    @Test func nilSampleClearsTheSession() {
        let track = Track(title: "Track", duration: 200)
        let engine = ScrobbleEngine()

        _ = engine.ingest(sample(track, at: 0, elapsed: 0))
        _ = engine.ingest(sample(track, at: 2, elapsed: 2))
        let effects = engine.ingest(nil)

        #expect(effects.isEmpty)
        #expect(engine.status == .idle)
    }

    @Test func playbackRateScalesPlayedTime() {
        let track = Track(title: "Track", duration: 200)
        let engine = ScrobbleEngine()

        _ = engine.ingest(sample(track, at: 0, elapsed: 0))
        _ = engine.ingest(sample(track, at: 2, elapsed: 2, rate: 2))

        #expect(abs(engine.status.played - 4) < 0.001)
    }

    @Test func progressAndRemainingFollowTheThreshold() {
        let track = Track(title: "Track", duration: 200)
        let engine = ScrobbleEngine()

        _ = engine.ingest(sample(track, at: 0, elapsed: 0))
        _ = engine.ingest(sample(track, at: 2, elapsed: 2))

        #expect(abs(engine.status.remaining - 98) < 0.001)
        #expect(abs(engine.status.progress - 0.02) < 0.001)
    }

    private func shortThresholdConfiguration() -> ScrobbleEngine.Configuration {
        ScrobbleEngine.Configuration(
            scrobblePercent: 0,
            maxThreshold: 0,
            minThreshold: 2,
            settleTime: 0.1,
            dedupWindow: 8,
            maxSampleGap: 5,
        )
    }
}
