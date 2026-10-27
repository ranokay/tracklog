import Foundation
import Testing
import TracklogCore

@Suite("Scrobble control")
@MainActor
struct ScrobbleControlTests: CaptureTestHelpers {
    @Test func reviseChangesTheSubmittedScrobbleWithoutMovingPlayedTime() {
        let track = Track(
            title: "Song",
            artist: "Artist",
            album: "Album",
            albumArtist: "Album Artist",
            duration: 30,
        )
        let revised = Track(
            title: "Song",
            artist: "Featured Artist",
            album: "Album",
            albumArtist: "Album Artist",
            duration: 30,
        )
        let engine = ScrobbleEngine()
        var effects: [ScrobbleEffect] = []

        _ = engine.ingest(sample(track, at: 0, elapsed: 0))
        _ = engine.ingest(sample(track, at: 2, elapsed: 2))
        let target = engine.status.target
        let played = engine.status.played

        engine.reviseSubmittedTrack(revised)
        #expect(engine.status.played == played)
        #expect(engine.status.target == target)

        for second in stride(from: 4.0, through: 30.0, by: 2.0) {
            effects += engine.ingest(sample(track, at: second, elapsed: second))
        }

        let scrobble = effects.compactMap { effect -> Scrobble? in
            if case let .scrobble(scrobble) = effect {
                return scrobble
            }
            return nil
        }.first
        #expect(scrobble?.raw == track, "the raw observation is kept for history and dedup")
        #expect(scrobble?.submitted == revised)
        #expect(scrobble?.playedAt == base)
        #expect(scrobble?.playedDuration == 30)
    }

    @Test func cancelSuppressesTheScrobbleUntilUndone() {
        let track = Track(title: "Track", duration: 30)
        let engine = ScrobbleEngine()

        for second in stride(from: 0.0, through: 28.0, by: 2.0) {
            _ = engine.ingest(sample(track, at: second, elapsed: second))
        }
        #expect(engine.cancelCurrentSession())
        #expect(engine.status.isCancelled)
        #expect(engine.status.canCancel == false)
        #expect(engine.status.canUndo)

        let cancelledEffects = stride(from: 30.0, through: 40.0, by: 2.0).flatMap { second in
            engine.ingest(sample(track, at: second, elapsed: second))
        }
        #expect(cancelledEffects.isEmpty)
        #expect(engine.status.phase == .armed)
        #expect(engine.status.played == 40, "played time keeps accumulating while cancelled")

        #expect(engine.undoCancelCurrentSession())
        #expect(engine.status.isCancelled == false)

        let effects = engine.ingest(sample(track, at: 42, elapsed: 42))
        #expect(
            effects == [
                .scrobble(
                    Scrobble(
                        raw: track,
                        playedAt: base,
                        playedDuration: 42,
                    ),
                ),
            ],
        )
    }

    @Test func cancelAfterTheThresholdHasNoEffect() {
        let track = Track(title: "Track", duration: 30)
        let engine = ScrobbleEngine()

        for second in stride(from: 0.0, through: 30.0, by: 2.0) {
            _ = engine.ingest(sample(track, at: second, elapsed: second))
        }
        #expect(engine.status.phase == .scrobbled)

        #expect(engine.cancelCurrentSession() == false)
        #expect(engine.status.isCancelled == false)
        #expect(engine.status.canCancel == false)
        #expect(engine.status.canUndo == false)
    }

    @Test func cancelDoesNotSurviveATrackChangeOrRestart() {
        let track = Track(title: "Track", duration: 200)
        let next = Track(title: "Next", duration: 200)
        let engine = ScrobbleEngine()

        _ = engine.ingest(sample(track, at: 0, elapsed: 0))
        _ = engine.ingest(sample(track, at: 2, elapsed: 2))
        #expect(engine.cancelCurrentSession())

        _ = engine.ingest(sample(next, at: 4, elapsed: 0))
        #expect(engine.status.isCancelled == false)
        #expect(engine.status.canCancel)

        #expect(engine.cancelCurrentSession())
        _ = engine.ingest(sample(next, at: 6, elapsed: 100))
        _ = engine.ingest(sample(next, at: 8, elapsed: 0))
        #expect(engine.status.isCancelled == false)
        #expect(engine.status.canCancel)
    }

    @Test func cancelledSessionIsNotFinalizedOnTrackChange() {
        let track = Track(title: "Track", duration: 30)
        let next = Track(title: "Next", duration: 30)
        let engine = ScrobbleEngine()

        for second in stride(from: 0.0, through: 4.0, by: 2.0) {
            _ = engine.ingest(sample(track, at: second, elapsed: second))
        }
        #expect(engine.cancelCurrentSession())
        #expect(engine.status.isCancelled)

        // Played past the threshold, then change track: the cancelled session
        // must not scrobble on the way out.
        for second in stride(from: 40.0, through: 70.0, by: 2.0) {
            _ = engine.ingest(sample(track, at: second, elapsed: second))
        }
        let effects = engine.ingest(sample(next, at: 72, elapsed: 0))
        #expect(effects.isEmpty)
        #expect(engine.status.isCancelled == false)
    }

    @Test func nowPlayingIsResentOnAResumeOnlyOnceStale() {
        let track = Track(title: "Track", duration: 200)
        let engine = ScrobbleEngine()
        var effects: [ScrobbleEffect] = []

        effects += engine.ingest(sample(track, at: 0, elapsed: 0))
        effects += engine.ingest(sample(track, at: 2, elapsed: 2))
        #expect(effects == [.nowPlaying(track)])

        effects = []
        effects += engine.ingest(sample(track, at: 4, elapsed: 4, playing: false))
        effects += engine.ingest(sample(track, at: 100, elapsed: 100))
        #expect(effects.isEmpty, "98 seconds after the send is inside ¾ of 200")

        effects = []
        effects += engine.ingest(sample(track, at: 110, elapsed: 110, playing: false))
        effects += engine.ingest(sample(track, at: 160, elapsed: 160))
        #expect(effects == [.nowPlaying(track)], "158 seconds is past the 150-second window")
    }

    @Test func nowPlayingStaleWindowIsCappedAtFourMinutes() {
        let track = Track(title: "Long", duration: 3600)

        // ¾ of an hour is 45 minutes, but the cap is four minutes.
        let atCap = ScrobbleEngine()
        _ = atCap.ingest(sample(track, at: 0, elapsed: 0))
        _ = atCap.ingest(sample(track, at: 2, elapsed: 2))
        _ = atCap.ingest(sample(track, at: 4, elapsed: 4, playing: false))
        #expect(atCap.ingest(sample(track, at: 242, elapsed: 242)).isEmpty, "exactly four minutes is not stale")

        let pastCap = ScrobbleEngine()
        _ = pastCap.ingest(sample(track, at: 0, elapsed: 0))
        _ = pastCap.ingest(sample(track, at: 2, elapsed: 2))
        _ = pastCap.ingest(sample(track, at: 4, elapsed: 4, playing: false))
        #expect(pastCap.ingest(sample(track, at: 243, elapsed: 243)) == [.nowPlaying(track)])
    }

    @Test func nowPlayingStaleWindowIsZeroForAnUnknownDuration() {
        let track = Track(title: "Stream", duration: 0)
        let engine = ScrobbleEngine()

        _ = engine.ingest(sample(track, at: 0, elapsed: 0))
        #expect(engine.ingest(sample(track, at: 2, elapsed: 2)) == [.nowPlaying(track)])
        _ = engine.ingest(sample(track, at: 4, elapsed: 4, playing: false))
        #expect(engine.ingest(sample(track, at: 6, elapsed: 6)) == [.nowPlaying(track)])
    }

    @Test func seekPauseAndRevisionDoNotResendOrWithdrawNowPlaying() {
        let track = Track(title: "Track", duration: 200)
        let revised = Track(title: "Track", artist: "Featured Artist", duration: 200)
        let engine = ScrobbleEngine()

        _ = engine.ingest(sample(track, at: 0, elapsed: 0))
        #expect(engine.ingest(sample(track, at: 2, elapsed: 2)) == [.nowPlaying(track)])

        engine.reviseSubmittedTrack(revised)
        #expect(engine.ingest(sample(track, at: 4, elapsed: 4)).isEmpty, "an edit never re-sends")

        #expect(engine.ingest(sample(track, at: 6, elapsed: 100)).isEmpty, "a seek never re-sends")
        #expect(engine.ingest(sample(track, at: 8, elapsed: 100, playing: false)).isEmpty)
        #expect(engine.status.isPlaying == false)
        #expect(engine.ingest(sample(track, at: 10, elapsed: 100)).isEmpty, "a resume inside the window is quiet")
    }
}
