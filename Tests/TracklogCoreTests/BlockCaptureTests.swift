import Foundation
import Testing
@testable import TracklogCore

@Suite("Block capture")
@MainActor
struct BlockCaptureTests: CaptureTestHelpers {
    @Test func aBlockedTrackProducesNoNowPlayingAndNoHistory() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        _ = try await store.save(blockRule(track: "Song", artist: "Artist"))

        let clock = FakeClock(base)
        var sent: [Track] = []
        let runtime = runtime(
            database: database,
            clock: clock,
            source: ReplayedNowPlaying(),
            sendNowPlaying: { sent.append($0) },
        )
        await runtime.start()

        await replay(thresholdSamples(track()), on: runtime, clock: clock)

        #expect(runtime.state.nowPlaying == nil)
        #expect(sent.isEmpty)
        #expect(runtime.state.listens.isEmpty)
        #expect(runtime.state.listenCount == 0)
        #expect(try await SQLiteListenStore(url: database.url).recent(limit: 10).isEmpty)
    }

    @Test func addingABlockLeavesExistingHistoryAlone() async throws {
        let database = try TemporaryDatabase()
        let clock = FakeClock(base)
        let runtime = runtime(
            database: database,
            clock: clock,
            source: ReplayedNowPlaying(),
        )
        await runtime.start()

        await replay(thresholdSamples(track()), on: runtime, clock: clock)
        let captured = try #require(runtime.state.listens.first)

        _ = try await runtime.saveBlock(
            blockRule(track: "Song", artist: "Artist", savedAt: base.addingTimeInterval(1)),
        )
        await replay(thresholdSamples(track(), offset: 600), on: runtime, clock: clock)

        #expect(runtime.state.listens == [captured])
        #expect(runtime.state.listenCount == 1)
        let stored = try await SQLiteListenStore(url: database.url).recent(limit: 10)
        #expect(stored == [captured])
    }

    @Test func savingAndDeletingABlockRefreshesThePageState() async throws {
        let database = try TemporaryDatabase()
        let runtime = runtime(
            database: database,
            clock: FakeClock(base),
            source: ReplayedNowPlaying(),
        )
        await runtime.start()
        #expect(runtime.state.blocks.isEmpty)

        let saved = try await runtime.saveBlock(blockRule(artist: "Artist"))

        #expect(saved.id != nil)
        #expect(runtime.state.blocks == [saved])

        try await runtime.deleteBlock(id: saved.id ?? -1)

        #expect(runtime.state.blocks.isEmpty)
    }

    @Test func refusesAnAllBlankBlockThroughTheRuntime() async throws {
        let database = try TemporaryDatabase()
        let runtime = runtime(
            database: database,
            clock: FakeClock(base),
            source: ReplayedNowPlaying(),
        )
        await runtime.start()

        await #expect(throws: BlockRuleValidationError.noFields) {
            _ = try await runtime.saveBlock(blockRule(track: " "))
        }

        #expect(runtime.state.blocks.isEmpty)
    }

    @Test func aBlockAddedMidTrackStopsTheCurrentListen() async throws {
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
        #expect(sent.count == 1)
        #expect(runtime.state.nowPlaying != nil)

        _ = try await runtime.saveBlock(blockRule(track: "Song", artist: "Artist"))

        await runtime.ingest(sample(track(), at: 4, elapsed: 4))
        await replay(thresholdSamples(track(), offset: 10), on: runtime, clock: clock)

        #expect(runtime.state.nowPlaying == nil)
        #expect(sent.count == 1, "a block never withdraws or re-sends now playing")
        #expect(runtime.state.listens.isEmpty)
    }
}
