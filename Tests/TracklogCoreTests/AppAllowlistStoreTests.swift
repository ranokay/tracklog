import Foundation
import Testing
@testable import TracklogCore

@Suite("App allowlist store")
struct AppAllowlistStoreTests {
    @Test func aNewDatabaseSeedsMusicAndSpotifyAsAllowed() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)

        let apps = try await store.apps()

        #expect(apps.map(\.bundleID) == SeededPlayers.bundleIDs)
        #expect(apps.map(\.isAllowed) == [true, true])
        #expect(try await store.isAllowed("com.apple.Music"))
        #expect(try await store.isAllowed("com.spotify.client"))
    }

    @Test func aDeniedAppStaysDeniedAfterReopen() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        try await store.setAllowed("com.apple.Music", allowed: false)
        await store.close()

        let reopened = try SQLiteListenStore(url: database.url)

        #expect(try await reopened.isAllowed("com.apple.Music") == false)
        #expect(try await reopened.isAllowed("com.spotify.client"))
        #expect(try await reopened.apps().count == 2, "opening the database does not reseed")
    }

    @Test func anUnseenAppIsDeniedAndJoinsTheListAtTheEnd() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)

        let seen = try #require(try await store.recordSeen("com.example.Video"))

        #expect(seen.bundleID == "com.example.Video")
        #expect(seen.isAllowed == false)
        #expect(try await store.isAllowed("com.example.Video") == false)
        #expect(try await store.apps().map(\.bundleID) == SeededPlayers.bundleIDs + ["com.example.Video"])
    }

    @Test func recordingAKnownAppKeepsItsDecisionAndDoesNotRelistIt() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let before = try await store.apps().count

        let seen = try #require(try await store.recordSeen("com.apple.Music"))

        #expect(seen.isAllowed, "a seen allowed app stays allowed")
        #expect(try await store.apps().count == before)
    }

    @Test func allowingAnAppPersistsAcrossReopen() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        _ = try await store.recordSeen("com.example.Video")
        try await store.setAllowed("com.example.Video", allowed: true)
        await store.close()

        let reopened = try SQLiteListenStore(url: database.url)
        let app = try #require(try await reopened.apps().first { $0.bundleID == "com.example.Video" })

        #expect(app.isAllowed)
        #expect(try await reopened.isAllowed("com.example.Video"))
    }

    @Test func anEmptyBundleIDIsDeniedAndNotListed() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)

        let seen = try await store.recordSeen("  ")

        #expect(seen == nil)
        #expect(try await store.isAllowed("") == false)
        #expect(try await store.isAllowed("  ") == false)
        #expect(try await store.apps().count == SeededPlayers.bundleIDs.count)
    }

    @Test func upgradingAnOlderDatabaseSeedsTheDefaultPlayers() async throws {
        let database = try TemporaryDatabase()
        let older = try SQLiteListenStore(
            url: database.url,
            migrations: Array(SQLiteListenStore.schemaMigrations.prefix(1)),
        )
        await older.close()

        let upgraded = try SQLiteListenStore(url: database.url)

        #expect(try await upgraded.userVersion() == SQLiteListenStore.schemaVersion)
        #expect(try await upgraded.apps().map(\.bundleID) == SeededPlayers.bundleIDs)
        #expect(try await upgraded.apps().map(\.isAllowed) == [true, true])
    }
}
