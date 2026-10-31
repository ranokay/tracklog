import Foundation
import Testing
import TracklogCore

@Suite("Scrobble engine lead-in")
@MainActor
struct ScrobbleEngineLeadInTests {
    private let base = Date(timeIntervalSince1970: 1_000_000)

    /// A sample whose player last reported its position at `reportedAt`, the
    /// way the helper keeps a track's start or a seek as its timestamp, and
    /// which Tracklog read at `observedAt`.
    private func sample(
        _ track: Track,
        reportedAt: TimeInterval,
        observedAt: TimeInterval,
        elapsed: TimeInterval,
        playing: Bool = true,
    ) -> MediaSample {
        MediaSample(
            track: track,
            elapsed: elapsed,
            playbackRate: playing ? 1 : 0,
            isPlaying: playing,
            timestamp: base.addingTimeInterval(reportedAt),
            observedAt: base.addingTimeInterval(observedAt),
        )
    }

    private func isScrobble(_ effect: ScrobbleEffect) -> Bool {
        if case .scrobble = effect {
            return true
        }
        return false
    }

    @Test func aTrackFoundLateCountsThePlaySinceItStarted() {
        let track = Track(title: "Track", duration: 40)
        let engine = ScrobbleEngine()
        var effects: [ScrobbleEffect] = []

        // The quiet poll and a slow helper read find the track 16 seconds in.
        for second in stride(from: 16.0, through: 40.0, by: 2.0) {
            effects += engine.ingest(sample(track, reportedAt: 0, observedAt: second, elapsed: second))
        }

        #expect(effects.filter(isScrobble) == [.scrobble(Scrobble(raw: track, playedAt: base, playedDuration: 30))])
    }

    @Test func aSeekCountsOnlyThePlaySinceTheSeek() {
        let engine = ScrobbleEngine()

        _ = engine.ingest(sample(Track(title: "Track", duration: 40), reportedAt: 18, observedAt: 19, elapsed: 19))

        #expect(engine.status.played == 1)
    }

    @Test func aTrackPlayingPastTheLeadInCountsNothingBeforeItWasSeen() {
        let engine = ScrobbleEngine()

        _ = engine.ingest(sample(Track(title: "Track", duration: 200), reportedAt: 0, observedAt: 21, elapsed: 21))

        #expect(engine.status.played == 0)
    }

    @Test func aPositionWithoutAPlayerReportCountsNothingBeforeIt() {
        let engine = ScrobbleEngine()

        // Automation reads a position but no report time: nothing proves the
        // track played without a seek.
        _ = engine.ingest(sample(Track(title: "Track", duration: 200), reportedAt: 10, observedAt: 10, elapsed: 10))

        #expect(engine.status.played == 0)
    }

    @Test func aPausedFirstSampleCountsNothingBeforeIt() {
        let engine = ScrobbleEngine()

        _ = engine.ingest(
            sample(Track(title: "Track", duration: 200), reportedAt: 0, observedAt: 10, elapsed: 10, playing: false),
        )

        #expect(engine.status.played == 0)
    }
}
