import Foundation
import Testing
@testable import TracklogCore

@Suite("Quick block")
@MainActor
struct QuickBlockTests: CaptureTestHelpers {
    private let rawTitle = "Song (Live)"
    private let rawArtist = "Artist"
    private let editedTitle = "Song"

    private func seededHistory(
        store: SQLiteListenStore,
        title _: String,
        start: TimeInterval = 0,
    ) async throws -> Listen {
        let raw = ListenMetadata(title: rawTitle, artist: rawArtist, album: "Album")
        let processed = ListenMetadata(title: editedTitle, artist: rawArtist, album: "Album")
        let listen = Listen(
            raw: raw,
            processed: processed,
            bundleID: "com.apple.Music",
            duration: 200,
            playedDuration: 200,
            startedAt: base.addingTimeInterval(start),
            capturedAt: base.addingTimeInterval(start),
        )
        return try #require(try await store.insert(listen))
    }

    private func rawSample(at offset: TimeInterval) -> MediaSample {
        sample(
            track(title: rawTitle, artist: rawArtist, album: "Album"),
            at: offset,
            elapsed: offset,
        )
    }

    @Test func blockingAHistoryRowUsesRawMetadataAndStopsTheNextPlay() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        _ = try await store.save(
            simpleEditRule(
                match: .init(track: rawTitle, artist: rawArtist),
                replace: .init(track: editedTitle),
            ),
        )
        let history = try await seededHistory(store: store, title: rawTitle)
        let before = try #require(try await store.recent(limit: 10).first)

        let clock = FakeClock(base)
        let runtime = runtime(database: database, clock: clock, source: ReplayedNowPlaying())
        await runtime.start()

        let block = try await runtime.quickBlock(history)
        #expect(block.track == rawTitle)
        #expect(block.artist == rawArtist)
        #expect(block.album.isEmpty)
        #expect(block.albumArtist.isEmpty)

        await runtime.ingest(rawSample(at: 2))

        #expect(runtime.state.nowPlaying == nil)
        #expect(try await store.count() == 1)
        let after = try #require(try await store.recent(limit: 10).first)
        #expect(after.raw == before.raw)
        #expect(after.processed == before.processed)
    }

    @Test func blockingTheCurrentTrackUsesTheEngineRawObservation() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        _ = try await store.save(
            simpleEditRule(
                match: .init(track: rawTitle, artist: rawArtist),
                replace: .init(track: editedTitle),
            ),
        )
        let history = try await seededHistory(store: store, title: rawTitle)
        let before = try #require(try await store.recent(limit: 10).first)

        let clock = FakeClock(base)
        var sent: [Track] = []
        let runtime = runtime(
            database: database,
            clock: clock,
            source: ReplayedNowPlaying(),
            sendNowPlaying: { sent.append($0) },
        )
        await runtime.start()

        await runtime.ingest(rawSample(at: 0))
        #expect(runtime.state.nowPlaying?.track.title == editedTitle)

        let block = try #require(try await runtime.quickBlockCurrentTrack())
        #expect(block.track == rawTitle)
        #expect(block.artist == rawArtist)
        #expect(block.album.isEmpty)
        #expect(block.albumArtist.isEmpty)

        let sentBeforeBlock = sent.count
        await runtime.ingest(rawSample(at: 2))

        #expect(runtime.state.nowPlaying == nil)
        #expect(try await store.count() == 1)
        #expect(sent.count == sentBeforeBlock)
        let after = try #require(try await store.recent(limit: 10).first)
        #expect(after.raw == before.raw)
        #expect(after.processed == before.processed)
    }
}
