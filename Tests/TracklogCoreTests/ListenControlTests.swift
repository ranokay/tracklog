import Foundation
import Testing
@testable import TracklogCore

@Suite("In-flight listen control")
@MainActor
struct ListenControlTests: CaptureTestHelpers {
    @Test func anEditSavedMidListenChangesTheScrobbleWithoutResettingPlayedTime() async throws {
        let database = try TemporaryDatabase()
        let clock = FakeClock(base)
        var sent: [Track] = []
        let runtime = runtime(
            database: database,
            clock: clock,
            source: ReplayedNowPlaying(),
            sendNowPlaying: { sent.append($0) },
        )
        await runtime.start()

        await runtime.ingest(sample(track(), at: 0, elapsed: 0))
        await runtime.ingest(sample(track(), at: 2, elapsed: 2))
        let target = runtime.state.status.target
        #expect(sent.count == 1)

        _ = try await runtime.saveSimpleEdit(
            simpleEditRule(match: .init(track: "Song"), replace: .init(artist: "Fixed Artist")),
        )

        await runtime.ingest(sample(track(), at: 4, elapsed: 4))
        #expect(abs(runtime.state.status.played - 4) < 0.001)
        #expect(runtime.state.status.target == target)
        #expect(sent.count == 1, "an edit never re-sends now playing")

        for second in stride(from: 6.0, through: 30.0, by: 2.0) {
            await runtime.ingest(sample(track(), at: second, elapsed: second))
        }

        let listen = try #require(runtime.state.listens.first)
        #expect(
            listen.raw == ListenMetadata(
                title: "Song",
                artist: "Artist",
                album: "Album",
                albumArtist: "Album Artist",
            ),
        )
        #expect(
            listen.processed == ListenMetadata(
                title: "Song",
                artist: "Fixed Artist",
                album: "Album",
                albumArtist: "Album Artist",
            ),
        )
        #expect(abs(listen.playedDuration - 30) < 0.001)
        #expect(listen.startedAt == base)
    }

    @Test func cancelSuppressesHistoryUntilUndo() async throws {
        let database = try TemporaryDatabase()
        let clock = FakeClock(base)
        let runtime = runtime(database: database, clock: clock, source: ReplayedNowPlaying())
        await runtime.start()

        for second in stride(from: 0.0, through: 28.0, by: 2.0) {
            await runtime.ingest(sample(track(), at: second, elapsed: second))
        }
        #expect(runtime.state.status.canCancel)
        #expect(runtime.cancelCurrentListen())
        #expect(runtime.state.status.isCancelled)
        #expect(runtime.state.status.canUndo)
        #expect(runtime.state.status.canCancel == false)

        for second in stride(from: 30.0, through: 40.0, by: 2.0) {
            await runtime.ingest(sample(track(), at: second, elapsed: second))
        }
        #expect(runtime.state.listens.isEmpty)
        #expect(runtime.state.listenCount == 0)
        #expect(try await SQLiteListenStore(url: database.url).recent(limit: 10).isEmpty)

        #expect(runtime.undoCancelCurrentListen())
        #expect(runtime.state.status.isCancelled == false)

        await runtime.ingest(sample(track(), at: 42, elapsed: 42))

        let listen = try #require(runtime.state.listens.first)
        #expect(abs(listen.playedDuration - 42) < 0.001, "undo resumes from the same played time")
        #expect(listen.startedAt == base)
    }

    @Test func cancelIsIneffectiveAfterTheThresholdFires() async throws {
        let database = try TemporaryDatabase()
        let clock = FakeClock(base)
        let runtime = runtime(database: database, clock: clock, source: ReplayedNowPlaying())
        await runtime.start()

        await replay(thresholdSamples(track()), on: runtime, clock: clock)
        #expect(runtime.state.status.phase == .scrobbled)

        #expect(runtime.cancelCurrentListen() == false)
        #expect(runtime.state.status.isCancelled == false)
        #expect(runtime.state.status.canCancel == false)
        #expect(runtime.state.status.canUndo == false)
    }

    @Test func editPrefillUsesRawValuesAndSkipsEmptyFields() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        _ = try await store.save(
            simpleEditRule(match: .init(track: "Song"), replace: .init(artist: "Fixed Artist")),
        )

        let clock = FakeClock(base)
        let runtime = runtime(database: database, clock: clock, source: ReplayedNowPlaying())
        await runtime.start()
        #expect(runtime.editMatchForCurrentListen() == nil)

        await runtime.ingest(sample(track(album: "", albumArtist: ""), at: 0, elapsed: 0))
        await runtime.ingest(sample(track(album: "", albumArtist: ""), at: 2, elapsed: 2))
        #expect(runtime.state.nowPlaying?.track.artist == "Fixed Artist", "the widget shows processed values")

        let match = try #require(runtime.editMatchForCurrentListen())
        #expect(match.track == "Song")
        #expect(match.artist == "Artist", "the edit form is prefilled from the raw values")
        #expect(match.album == nil)
        #expect(match.albumArtist == nil)

        await runtime.ingest(sample(track(title: "Next", artist: "Other"), at: 4, elapsed: 0))

        let next = try #require(runtime.editMatchForCurrentListen())
        #expect(next.track == "Next")
        #expect(next.artist == "Other")
    }
}
