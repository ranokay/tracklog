import Foundation
import Testing
import TracklogCore
import TracklogMedia

/// The helper's `get --now` answers, as measured in #125: `timestamp` is when
/// the player last reported its position (start, pause, resume or seek) and
/// `elapsedTime` is the position at that moment.
@Suite("Media helper position")
@MainActor
struct MediaHelperPositionTests {
    private let start = Date(timeIntervalSince1970: 2_000_000)

    private func answer(
        reportedAt: TimeInterval,
        position: TimeInterval,
        playing: Bool = true,
        duration: TimeInterval = 200,
    ) throws -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return try JSONSerialization.data(withJSONObject: ["payload": [
            "title": "Song",
            "artist": "Artist",
            "duration": duration,
            "elapsedTime": position,
            "playbackRate": playing ? 1.0 : 0.0,
            "playing": playing,
            "parentApplicationBundleIdentifier": "com.apple.Music",
            "timestamp": formatter.string(from: start.addingTimeInterval(reportedAt)),
        ]])
    }

    private func read(_ data: Data, at offset: TimeInterval) throws -> MediaSample {
        try #require(MediaHelperPayload.decode(data, observedAt: start.addingTimeInterval(offset)))
    }

    @Test func aLongPauseDoesNotInflateThePosition() throws {
        let playing = try read(answer(reportedAt: 0, position: 0), at: 20)
        #expect(abs(playing.elapsed - 20) < 0.01)

        // Paused at 0:20; the helper keeps that report for five minutes.
        let paused = try read(answer(reportedAt: 20, position: 20, playing: false), at: 320)
        #expect(abs(paused.elapsed - 20) < 0.01)

        // Resumed: the helper reports the resume, so the position is about
        // 0:20 plus the two seconds since, not 5:20.
        let resumed = try read(answer(reportedAt: 320, position: 20), at: 322)
        #expect(abs(resumed.elapsed - 22) < 0.01)
    }

    @Test func aMidTrackReportKeepsAdvancingWhilePlaying() throws {
        // Measured: elapsedTime 174.6 reported at the resume, read 8.5 s later
        // while Music said 183.3. The position must not stay at 174.6.
        let sample = try read(answer(reportedAt: 0, position: 174.6, duration: 269), at: 8.5)

        #expect(abs(sample.elapsed - 183.1) < 0.01)
    }

    @Test func aForwardThenBackwardSeekInTheFirstTwentySecondsKeepsOneSession() throws {
        let engine = ScrobbleEngine()
        var effects: [ScrobbleEffect] = []

        for second in stride(from: 1.0, through: 9.0, by: 2.0) {
            effects += try engine.ingest(read(answer(reportedAt: 0, position: 0), at: second))
        }
        // Seek forward to 0:40 at 0:10, then back to 0:05 at 0:14.
        for second in [11.0, 13.0] {
            effects += try engine.ingest(read(answer(reportedAt: 10, position: 40), at: second))
        }
        for second in stride(from: 15.0, through: 19.0, by: 2.0) {
            effects += try engine.ingest(read(answer(reportedAt: 14, position: 5), at: second))
        }
        #expect(abs(engine.status.played - 19) < 0.01, "the backward seek keeps all 19 seconds played")

        for second in stride(from: 21.0, through: 121.0, by: 2.0) {
            effects += try engine.ingest(read(answer(reportedAt: 14, position: 5), at: second))
        }
        let scrobbles = effects.compactMap { effect -> Scrobble? in
            if case let .scrobble(scrobble) = effect {
                return scrobble
            }
            return nil
        }
        #expect(scrobbles.count == 1)
        #expect(scrobbles.first?.playedAt == start, "the listen keeps the original start")
    }
}
