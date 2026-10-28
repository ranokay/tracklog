import Foundation
import Testing
@testable import TracklogCore

@Suite("Artwork store")
struct ArtworkStoreTests {
    private let base = Date(timeIntervalSince1970: 1_000_000)

    private func artwork(
        hash: String = "hash-a",
        data: Data = Data([1, 2, 3, 4]),
        width: Int = 2,
        height: Int = 2,
    ) -> StoredArtwork {
        StoredArtwork(hash: hash, data: data, pixelWidth: width, pixelHeight: height)
    }

    private func listen(
        title: String = "Song",
        start: TimeInterval = 0,
    ) -> Listen {
        let metadata = ListenMetadata(title: title, artist: "Artist", album: "Album")
        return Listen(
            raw: metadata,
            processed: metadata,
            bundleID: "com.apple.Music",
            duration: 200,
            playedDuration: 100,
            startedAt: base.addingTimeInterval(start),
            capturedAt: base.addingTimeInterval(start),
        )
    }

    private func identity(of listen: Listen) -> String {
        listen.raw.identity
    }

    @Test func storesArtworkOncePerContentHash() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)

        try await store.attachArtwork(artwork(hash: "shared", data: Data([7])), toTrack: "track-a")
        try await store.attachArtwork(artwork(hash: "shared", data: Data([7])), toTrack: "track-b")

        #expect(try await store.artwork(for: "shared") == Data([7]))
        #expect(try await store.artworkCount() == 1)
    }

    @Test func aListenInsertedAfterArtworkReferencesIt() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let listen = listen()

        try await store.attachArtwork(artwork(hash: "cover"), toTrack: identity(of: listen))
        let stored = try #require(try await store.insert(listen))

        #expect(stored.artworkHash == "cover")
        #expect(try await store.recent(limit: 1).first?.artworkHash == "cover")
    }

    @Test func attachingArtworkUpdatesListensAlreadyStored() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let stored = try #require(try await store.insert(listen()))
        #expect(stored.artworkHash == nil)

        try await store.attachArtwork(artwork(hash: "later"), toTrack: identity(of: stored))

        #expect(try await store.recent(limit: 1).first?.artworkHash == "later")
    }

    @Test func artworkAndItsReferencesSurviveReopeningTheDatabase() async throws {
        let database = try TemporaryDatabase()
        let first = try SQLiteListenStore(url: database.url)
        let original = listen(title: "Reused")
        try await first.attachArtwork(artwork(hash: "durable", data: Data([9, 9])), toTrack: identity(of: original))
        _ = try await first.insert(original)
        await first.close()

        let reopened = try SQLiteListenStore(url: database.url)
        let reused = try #require(try await reopened.insert(listen(title: "Reused", start: 10)))

        #expect(try await reopened.artwork(for: "durable") == Data([9, 9]))
        #expect(reused.artworkHash == "durable")
    }

    @Test func aNewCoverForTheSameTrackAppliesToLaterListensOnly() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let original = try #require(try await store.insert(listen()))
        try await store.attachArtwork(artwork(hash: "old"), toTrack: identity(of: original))

        try await store.attachArtwork(artwork(hash: "new"), toTrack: identity(of: original))
        let later = try #require(try await store.insert(listen(start: 10)))

        #expect(later.artworkHash == "new")
        #expect(try await store.page(limit: 10, before: nil).first(where: { $0.id == original.id })?.artworkHash == "old")
        #expect(try await store.artworkHash(forTrack: identity(of: original)) == "new")
    }

    @Test func artworklessHistoryKeepsANilHash() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)

        let stored = try #require(try await store.insert(listen()))

        #expect(stored.artworkHash == nil)
        #expect(try await store.artwork(for: "missing") == nil)
        #expect(try await store.artworkHash(forTrack: identity(of: stored)) == nil)
    }

    @Test func aListenFromBeforeArtworkSupportGetsTheCoverWhenItsTrackPlaysAgain() async throws {
        let database = try TemporaryDatabase()
        let versionFour = Array(SQLiteListenStore.schemaMigrations.prefix(4))
        let old = try SQLiteListenStore(url: database.url, migrations: versionFour)
        let metadata = ListenMetadata(title: "\tSong Ä\n", artist: " ARTIST ", album: "Album")
        let legacy = try database.insertLegacyListen(
            Listen(
                raw: metadata,
                processed: metadata,
                bundleID: "com.apple.Music",
                duration: 200,
                playedDuration: 100,
                startedAt: base,
                capturedAt: base.addingTimeInterval(10),
            ),
        )
        await old.close()

        let upgraded = try SQLiteListenStore(url: database.url)
        try await upgraded.attachArtwork(artwork(hash: "legacy-cover"), toTrack: legacy.raw.identity)

        #expect(try await upgraded.recent(limit: 1).first?.artworkHash == "legacy-cover")
    }
}
