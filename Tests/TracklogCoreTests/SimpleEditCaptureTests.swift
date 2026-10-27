import Foundation
import Testing
@testable import TracklogCore

@Suite("Simple edits capture")
@MainActor
struct SimpleEditCaptureTests: CaptureTestHelpers {
    @Test func aSimpleEditChangesProcessedMetadataAndKeepsTheRawValues() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let edit = try await store.save(
            simpleEditRule(match: .init(track: "song"), replace: .init(artist: "Fixed Artist")),
        )

        let clock = FakeClock(base)
        let runtime = runtime(database: database, clock: clock, source: ReplayedNowPlaying())
        await runtime.start()
        #expect(runtime.state.simpleEdits == [edit])

        await replay(thresholdSamples(track()), on: runtime, clock: clock)

        let listen = try #require(runtime.state.listens.first)
        #expect(listen.raw == ListenMetadata(
            title: "Song",
            artist: "Artist",
            album: "Album",
            albumArtist: "Album Artist",
        ))
        #expect(listen.processed == ListenMetadata(
            title: "Song",
            artist: "Fixed Artist",
            album: "Album",
            albumArtist: "Album Artist",
        ))
    }

    @Test func aSimpleEditChangesNowPlayingMetadata() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        _ = try await store.save(
            simpleEditRule(match: .init(track: "song"), replace: .init(artist: "Fixed Artist")),
        )

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

        #expect(runtime.state.nowPlaying?.track.title == "Song")
        #expect(runtime.state.nowPlaying?.track.artist == "Fixed Artist")
        #expect(sent.map(\.artist) == ["Fixed Artist"])
        #expect(sent.map(\.title) == ["Song"])
    }

    @Test func sentinelCleanupIsPartOfTheStoredProcessedMetadata() async throws {
        let database = try TemporaryDatabase()
        let clock = FakeClock(base)
        let runtime = runtime(database: database, clock: clock, source: ReplayedNowPlaying())
        await runtime.start()

        await replay(
            thresholdSamples(
                track(album: "Unknown Album", albumArtist: "VA"),
            ),
            on: runtime,
            clock: clock,
        )

        let listen = try #require(runtime.state.listens.first)
        #expect(listen.processed.album.isEmpty)
        #expect(listen.processed.albumArtist == "Various Artists")
    }

    @Test func aLaterRuleChangeDoesNotRewriteStoredHistory() async throws {
        let database = try TemporaryDatabase()
        let firstRule = simpleEditRule(
            match: .init(track: "song"),
            replace: .init(artist: "First Artist"),
            savedAt: base.addingTimeInterval(1),
        )
        let store = try SQLiteListenStore(url: database.url)
        _ = try await store.save(firstRule)

        let clock = FakeClock(base)
        let runtime = runtime(database: database, clock: clock, source: ReplayedNowPlaying())
        await runtime.start()
        await replay(thresholdSamples(track()), on: runtime, clock: clock)
        let captured = try #require(runtime.state.listens.first)
        #expect(captured.processed.artist == "First Artist")

        // The same active match tuple replaces the old rule, so the next play
        // is processed by the new replacement.
        _ = try await runtime.saveSimpleEdit(
            simpleEditRule(
                match: .init(track: "song"),
                replace: .init(artist: "Second Artist"),
                savedAt: base.addingTimeInterval(2),
            ),
        )

        #expect(runtime.state.listens.first?.processed.artist == "First Artist")

        await replay(thresholdSamples(track(), offset: 600), on: runtime, clock: clock)

        let stored = try await SQLiteListenStore(url: database.url).recent(limit: 10)
        #expect(stored.count == 2)
        #expect(stored.last?.processed.artist == "First Artist")
        let second = try #require(stored.first { $0.processed.artist == "Second Artist" })
        #expect(second.raw.artist == "Artist")
    }

    @Test func savingAndDeletingARuleRefreshesThePageState() async throws {
        let database = try TemporaryDatabase()
        let runtime = runtime(
            database: database,
            clock: FakeClock(base),
            source: ReplayedNowPlaying(),
        )
        await runtime.start()
        #expect(runtime.state.simpleEdits.isEmpty)

        let saved = try await runtime.saveSimpleEdit(
            simpleEditRule(match: .init(track: "song"), replace: .init(album: "Fixed Album")),
        )

        #expect(saved.id != nil)
        #expect(runtime.state.simpleEdits == [saved])

        try await runtime.deleteSimpleEdit(id: saved.id ?? -1)

        #expect(runtime.state.simpleEdits.isEmpty)
    }

    @Test func aListenDroppedBySentinelCleanupIsNotStored() async throws {
        let database = try TemporaryDatabase()
        let clock = FakeClock(base)
        let runtime = runtime(database: database, clock: clock, source: ReplayedNowPlaying())
        await runtime.start()

        await replay(thresholdSamples(track(artist: "VA")), on: runtime, clock: clock)

        #expect(runtime.state.listens.isEmpty)
        #expect(runtime.state.listenCount == 0)
    }
}
