import Foundation
import Testing
import TracklogCore

@Suite("Observation clock")
@MainActor
struct ObservationClockTests {
    private let base = Date(timeIntervalSince1970: 1_000_000)

    @Test func playedTimeFollowsObservationNotTheReportedTimestamp() {
        let track = Track(title: "Track", duration: 200)
        let engine = ScrobbleEngine()

        // A helper that repeats the track start while elapsed stays zero must
        // not freeze the session; the observation clock still advances.
        for step in 0 ... 2 {
            _ = engine.ingest(MediaSample(
                track: track,
                elapsed: 0,
                playbackRate: 1,
                isPlaying: true,
                timestamp: base,
                observedAt: base.addingTimeInterval(Double(step) * 2),
            ))
        }

        #expect(abs(engine.status.played - 4) < 0.001)
    }
}
