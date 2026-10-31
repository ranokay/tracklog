import Foundation
import Testing
import TracklogCore

@Suite("Scrobble engine lead-in")
@MainActor
struct ScrobbleEngineLeadInTests {
    private let base = Date(timeIntervalSince1970: 1_000_000)

    private func sample(
        _ track: Track,
        at offset: TimeInterval,
        elapsed: TimeInterval,
        playing: Bool = true,
    ) -> MediaSample {
        MediaSample(
            track: track,
            elapsed: elapsed,
            playbackRate: playing ? 1 : 0,
            isPlaying: playing,
            timestamp: base.addingTimeInterval(offset),
        )
    }

    @Test func aTrackFirstSeenInItsLeadInCountsThoseSecondsAsPlayed() {
        let track = Track(title: "Track", duration: 40)
        let engine = ScrobbleEngine()
        var effects: [ScrobbleEffect] = []

        // A 15-second quiet poll and a slow helper read find the track 16
        // seconds after it started.
        for second in stride(from: 16.0, through: 40.0, by: 2.0) {
            effects += engine.ingest(sample(track, at: second, elapsed: second))
        }

        #expect(effects.filter(isScrobble) == [.scrobble(Scrobble(raw: track, playedAt: base, playedDuration: 30))])
    }

    private func isScrobble(_ effect: ScrobbleEffect) -> Bool {
        if case .scrobble = effect {
            return true
        }
        return false
    }

    @Test func aTrackFirstSeenPastItsLeadInCountsOnlyWhatPlaysAfter() {
        let engine = ScrobbleEngine()

        _ = engine.ingest(sample(Track(title: "Track", duration: 200), at: 0, elapsed: 21))

        #expect(engine.status.played == 0)
    }

    @Test func aPausedFirstSampleCountsNothingBeforeIt() {
        let engine = ScrobbleEngine()

        _ = engine.ingest(sample(Track(title: "Track", duration: 200), at: 0, elapsed: 10, playing: false))

        #expect(engine.status.played == 0)
    }
}
