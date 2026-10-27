import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import TracklogCore
import UniformTypeIdentifiers

@Suite("Capture artwork")
@MainActor
struct CaptureArtworkTests: CaptureTestHelpers {
    @Test func oneArtworkLookupHappensPerTrackIdentityChange() async throws {
        let database = try TemporaryDatabase()
        let clock = FakeClock(base)
        let source = ReplayedNowPlaying()
        source.artworkData = try #require(testImageData())
        let runtime = runtime(database: database, clock: clock, source: source)
        await runtime.start()

        let first = track(title: "First")
        await replay(Array(thresholdSamples(first).prefix(3)), on: runtime, clock: clock)
        await eventually { source.artworkLookups.count == 1 }
        #expect(source.artworkLookups.count == 1)
        #expect(runtime.state.nowPlayingArtworkIdentity == ListenMetadata(first).identity)

        await replay(Array(thresholdSamples(first).dropFirst(3)), on: runtime, clock: clock)
        await eventually { runtime.state.listens.count == 1 }
        #expect(source.artworkLookups.count == 1, "polls of the same track must not look art up again")

        let second = track(title: "Second")
        await replay(Array(thresholdSamples(second, offset: 60).prefix(2)), on: runtime, clock: clock)
        await eventually { source.artworkLookups.count == 2 }
        #expect(source.artworkLookups.count == 2)
    }

    @Test func oneImageIsStoredOnceAndSharedByEveryListenThatFindsIt() async throws {
        let database = try TemporaryDatabase()
        let clock = FakeClock(base)
        let source = ReplayedNowPlaying()
        source.artworkData = try #require(testImageData())
        let runtime = runtime(database: database, clock: clock, source: source)
        await runtime.start()

        await replay(thresholdSamples(track(title: "First")), on: runtime, clock: clock)
        await eventually { runtime.state.listens.first?.artworkHash != nil }
        let firstHash = try #require(runtime.state.listens.first?.artworkHash)

        await replay(
            thresholdSamples(track(title: "Second"), offset: 100),
            on: runtime,
            clock: clock,
        )
        await eventually { runtime.state.listens.first?.artworkHash != nil && runtime.state.listens.count == 2 }

        let hashes = Set(runtime.state.listens.compactMap(\.artworkHash))
        #expect(hashes == [firstHash])
        #expect(source.artworkLookups.count == 2, "a second track identity gets its own lookup")
        let store = try SQLiteListenStore(url: database.url)
        #expect(try await store.artworkCount() == 1)
    }

    @Test func storedArtworkIsReusedOnTheNextLaunchWithoutALookup() async throws {
        let database = try TemporaryDatabase()
        let firstClock = FakeClock(base)
        let firstSource = ReplayedNowPlaying()
        firstSource.artworkData = try #require(testImageData())
        let first = runtime(database: database, clock: firstClock, source: firstSource)
        await first.start()

        await replay(thresholdSamples(track()), on: first, clock: firstClock)
        await eventually { first.state.listens.first?.artworkHash != nil }
        let hash = try #require(first.state.listens.first?.artworkHash)
        first.stop()

        let secondClock = FakeClock(base)
        let secondSource = ReplayedNowPlaying()
        let second = runtime(database: database, clock: secondClock, source: secondSource)
        await second.start()

        #expect(second.state.listens.first?.artworkHash == hash)
        #expect(second.state.artworkByHash[hash] != nil)
        #expect(secondSource.artworkLookups.isEmpty)
    }

    @Test func aSlowArtworkReadNeverDelaysTheScrobble() async throws {
        let database = try TemporaryDatabase()
        let clock = FakeClock(base)
        let source = ReplayedNowPlaying()
        source.artworkData = try #require(testImageData())
        source.artworkDelay = .seconds(10)
        let runtime = runtime(database: database, clock: clock, source: source)
        await runtime.start()

        await replay(thresholdSamples(track()), on: runtime, clock: clock)

        #expect(runtime.state.listens.count == 1, "capture must not wait on artwork")
        #expect(runtime.state.lastListen != nil)
        #expect(runtime.state.failure == nil)
        runtime.stop()
    }

    @Test func aMissingOrFailedArtworkReadLeavesTheListenAndTheNeutralSleeve() async throws {
        let database = try TemporaryDatabase()
        let clock = FakeClock(base)
        let source = ReplayedNowPlaying()
        source.artworkData = nil
        let runtime = runtime(database: database, clock: clock, source: source)
        await runtime.start()

        await replay(thresholdSamples(track()), on: runtime, clock: clock)
        await eventually { source.artworkLookups.count == 1 }

        #expect(runtime.state.listens.count == 1)
        #expect(runtime.state.listens.first?.artworkHash == nil)
        #expect(runtime.state.nowPlayingArtwork == nil)
        #expect(runtime.state.failure == nil)
    }

    @Test func aStoredCoverLoadsForNowPlayingWithoutAskingTheSource() async throws {
        let database = try TemporaryDatabase()
        let firstClock = FakeClock(base)
        let firstSource = ReplayedNowPlaying()
        firstSource.artworkData = try #require(testImageData())
        let first = runtime(database: database, clock: firstClock, source: firstSource)
        await first.start()
        await replay(thresholdSamples(track()), on: first, clock: firstClock)
        await eventually { first.state.listens.first?.artworkHash != nil }
        let hash = try #require(first.state.listens.first?.artworkHash)
        let stored = try await SQLiteListenStore(url: database.url).artwork(for: hash)
        first.stop()

        let secondClock = FakeClock(base)
        let secondSource = ReplayedNowPlaying()
        secondSource.artworkData = try #require(testImageData(red: 0.9, green: 0.1, blue: 0.1))
        let second = runtime(database: database, clock: secondClock, source: secondSource)
        await second.start()
        await replay([sample(track(), at: 0, elapsed: 0)], on: second, clock: secondClock)
        await eventually { second.state.nowPlayingArtwork != nil }

        #expect(second.state.nowPlayingArtwork == stored)
        #expect(second.state.nowPlayingArtworkIdentity == ListenMetadata(track()).identity)
        #expect(secondSource.artworkLookups.isEmpty, "a stored cover is reused before the source")
    }
}
