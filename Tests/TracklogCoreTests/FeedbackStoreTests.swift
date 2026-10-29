import Foundation
import Testing
@testable import TracklogCore

@Suite("Feedback store")
@MainActor
struct FeedbackStoreTests {
    private let base = Date(timeIntervalSince1970: 1_000_000)

    private func identity(title: String = "Song", artist: String = "Artist") -> String {
        ListenMetadata(title: title, artist: artist, album: "Album").identity
    }

    @Test func savesReadsUpdatesAndRemovesFeedback() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let track = identity()

        try await store.setFeedback(.loved, for: track, at: base)
        let loved = try #require(try await store.feedback(for: [track])[track])
        #expect(loved.identity == track)
        #expect(loved.score == .loved)
        #expect(loved.updatedAt == base)

        try await store.setFeedback(.hated, for: track, at: base.addingTimeInterval(10))
        let hated = try #require(try await store.feedback(for: [track])[track])
        #expect(hated.score == .hated)
        #expect(hated.updatedAt == base.addingTimeInterval(10))

        try await store.setFeedback(nil, for: track, at: base.addingTimeInterval(20))
        #expect(try await store.feedback(for: [track]).isEmpty)
    }

    @Test func readsOnlyTheRequestedIdentitiesOnce() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let first = identity(title: "First")
        let second = identity(title: "Second")
        try await store.setFeedback(.loved, for: first, at: base)
        try await store.setFeedback(.hated, for: second, at: base)

        let loaded = try await store.feedback(for: [first, first, second, identity(title: "Unknown")])

        #expect(loaded.count == 2)
        #expect(loaded[first]?.score == .loved)
        #expect(loaded[second]?.score == .hated)
    }

    @Test func feedbackSurvivesAReopen() async throws {
        let database = try TemporaryDatabase()
        let track = identity()
        do {
            let store = try SQLiteListenStore(url: database.url)
            try await store.setFeedback(.loved, for: track, at: base)
            await store.close()
        }

        let reopened = try SQLiteListenStore(url: database.url)
        let loaded = try #require(try await reopened.feedback(for: [track])[track])
        #expect(loaded.score == .loved)
        #expect(loaded.updatedAt == base)
    }

    @Test func feedbackIdentityIgnoresTheSourcePlayerBundleID() {
        let fromMusic = Listen(
            raw: ListenMetadata(title: "Song", artist: "Artist", album: "Album"),
            processed: ListenMetadata(title: "Song", artist: "Artist", album: "Album"),
            bundleID: "com.apple.Music",
            duration: 200,
            playedDuration: 100,
            startedAt: base,
            capturedAt: base,
        )
        let fromSpotify = Listen(
            raw: ListenMetadata(title: "Song", artist: "Artist", album: "Album"),
            processed: ListenMetadata(title: "Song", artist: "Artist", album: "Album"),
            bundleID: "com.spotify.client",
            duration: 200,
            playedDuration: 100,
            startedAt: base,
            capturedAt: base,
        )

        #expect(fromMusic.processed.identity == fromSpotify.processed.identity)
        #expect(fromMusic.processedTrack.identity != fromSpotify.processedTrack.identity)
    }

    @Test func migratesFromThePreviousSchemaAndKeepsHistory() async throws {
        let database = try TemporaryDatabase()
        let previous = SQLiteListenStore.schemaMigrations.filter { $0.version <= 8 }
        let listen = deliveryListen(title: "Before feedback", base: base)
        do {
            let store = try SQLiteListenStore(url: database.url, migrations: previous)
            #expect(try await store.userVersion() == 8)
            _ = try await store.insert(listen)
            await store.close()
        }

        let upgraded = try SQLiteListenStore(url: database.url)
        #expect(try await upgraded.userVersion() == SQLiteListenStore.schemaVersion)
        #expect(database.backupCount() == 1)
        #expect(try await upgraded.recent(limit: 10).map(\.processed.title) == ["Before feedback"])

        let track = listen.processed.identity
        try await upgraded.setFeedback(.hated, for: track, at: base)
        #expect(try await upgraded.feedback(for: [track])[track]?.score == .hated)
    }
}
