import Foundation
import Testing
@testable import TracklogCore

@Suite("Listen store")
struct ListenStoreTests {
    private let base = Date(timeIntervalSince1970: 1_000_000)

    private func metadata(title: String = "Song", artist: String = "Artist") -> ListenMetadata {
        ListenMetadata(title: title, artist: artist, album: "Album", albumArtist: "Album Artist")
    }

    private func listen(
        title: String = "Song",
        artist: String = "Artist",
        start: TimeInterval = 0,
        captured: TimeInterval = 0,
    ) -> Listen {
        Listen(
            raw: metadata(title: title, artist: artist),
            processed: metadata(title: title, artist: artist),
            bundleID: "com.apple.Music",
            duration: 200,
            playedDuration: 100,
            startedAt: base.addingTimeInterval(start),
            capturedAt: base.addingTimeInterval(captured),
        )
    }

    @Test func storesAndReadsBackEveryField() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let original = listen(start: 10, captured: 20)

        let stored = try await store.insert(original)
        let recent = try await store.recent(limit: 10)

        #expect(stored != nil)
        #expect(stored?.id != nil)
        #expect(recent == [stored])
        #expect(recent.first?.raw == original.raw)
        #expect(recent.first?.processed == original.processed)
        #expect(recent.first?.bundleID == "com.apple.Music")
        #expect(recent.first?.duration == 200)
        #expect(recent.first?.playedDuration == 100)
        #expect(recent.first?.startedAt == base.addingTimeInterval(10))
        #expect(recent.first?.capturedAt == base.addingTimeInterval(20))
    }

    @Test func duplicateRawIdentityAndStartInsertsNothing() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let first = listen()

        let stored = try await store.insert(first)
        let differentCase = Listen(
            raw: ListenMetadata(title: "  song ", artist: "ARTIST", album: "album", albumArtist: "album artist"),
            processed: metadata(),
            bundleID: "com.apple.Music",
            duration: 200,
            playedDuration: 200,
            startedAt: base,
            capturedAt: base.addingTimeInterval(999),
        )
        let duplicate = try await store.insert(differentCase)

        #expect(stored != nil)
        #expect(duplicate == nil)
        #expect(try await store.recent(limit: 10).count == 1)
    }

    @Test func subSecondStartJitterStillDeduplicates() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)

        #expect(try await store.insert(listen()) != nil)
        #expect(try await store.insert(listen(start: 0.4)) == nil)
        #expect(try await store.recent(limit: 10).count == 1)
    }

    @Test func sameIdentityAtAnotherStartIsAnotherListen() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)

        #expect(try await store.insert(listen()) != nil)
        #expect(try await store.insert(listen(start: 1)) != nil)
        #expect(try await store.recent(limit: 10).count == 2)
    }

    @Test func recentIsNewestFirst() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let oldest = try #require(try await store.insert(listen(title: "Oldest", start: 100)))
        let newest = try #require(try await store.insert(listen(title: "Newest", start: 300)))
        let middle = try #require(try await store.insert(listen(title: "Middle", start: 200)))

        let recent = try await store.recent(limit: 10)

        #expect(recent.map(\.id) == [newest.id, middle.id, oldest.id])
    }

    @Test func pagesThroughHistoryWithoutDuplicatesAndCountsIt() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        for index in 0 ..< 205 {
            _ = try await store.insert(listen(title: "Song \(index)", start: TimeInterval(index)))
        }

        let first = try await store.page(limit: 100, before: nil)
        let firstCursor = try #require(first.last.flatMap(ListenCursor.init))
        let second = try await store.page(limit: 100, before: firstCursor)
        let secondCursor = try #require(second.last.flatMap(ListenCursor.init))
        let third = try await store.page(limit: 100, before: secondCursor)

        #expect(first.count == 100)
        #expect(second.count == 100)
        #expect(third.count == 5)
        let paged = first + second + third
        #expect(Set(paged.compactMap(\.id)).count == 205)
        #expect(
            paged.map(\.startedAt)
                == (0 ..< 205).reversed().map { base.addingTimeInterval(TimeInterval($0)) },
        )
        #expect(try await store.count() == 205)
    }

    @Test func countsListensInADateRange() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        _ = try await store.insert(listen(title: "Before", start: -100))
        _ = try await store.insert(listen(title: "First", start: 10))
        _ = try await store.insert(listen(title: "Second", start: 90))
        _ = try await store.insert(listen(title: "After", start: 300))

        let count = try await store.count(in: base ..< base.addingTimeInterval(100))

        #expect(count == 2)
    }

    @Test func freshDatabaseUsesTheCurrentSchemaWithForeignKeysOn() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)

        #expect(try await store.userVersion() == SQLiteListenStore.schemaVersion)
        #expect(try await store.foreignKeysEnabled())
    }

    @Test func migrationCopiesABackupFirstAndKeepsTheData() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let stored = try #require(try await store.insert(listen()))
        await store.close()

        let migrations = SQLiteListenStore.schemaMigrations + [
            SQLiteListenStore.Migration(version: 3) { handle in
                try SQLiteListenStore.execute(handle, "ALTER TABLE listens ADD COLUMN note TEXT NOT NULL DEFAULT ''")
            },
        ]
        let migrated = try SQLiteListenStore(url: database.url, migrations: migrations)

        #expect(try await migrated.userVersion() == 3)
        #expect(try await migrated.recent(limit: 10) == [stored])
        #expect(database.backupCount() == 1)
        #expect(try database.userVersion() == 3)
    }

    @Test func failedMigrationRollsBackAndKeepsTheOriginal() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let stored = try #require(try await store.insert(listen()))
        await store.close()

        let migrations = SQLiteListenStore.schemaMigrations + [
            SQLiteListenStore.Migration(version: 3) { handle in
                try SQLiteListenStore.execute(handle, "ALTER TABLE listens ADD COLUMN note TEXT NOT NULL DEFAULT ''")
            },
            SQLiteListenStore.Migration(version: 4) { handle in
                try SQLiteListenStore.execute(handle, "ALTER TABLE listens ADD COLUMN broken")
                throw DatabaseError.sqlite("simulated migration failure")
            },
        ]

        #expect(throws: DatabaseError.self) {
            _ = try SQLiteListenStore(url: database.url, migrations: migrations)
        }

        #expect(try database.userVersion() == SQLiteListenStore.schemaVersion)
        #expect(database.backupCount() == 1)
        #expect(try database.hasColumn("note", in: "listens") == false)

        let reopened = try SQLiteListenStore(url: database.url)
        #expect(try await reopened.recent(limit: 10) == [stored])
    }

    @Test func newerSchemaIsRefusedWithoutChangingTheFile() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        #expect(try await store.insert(listen()) != nil)
        await store.close()
        try database.setUserVersion(99)

        do {
            _ = try SQLiteListenStore(url: database.url)
            Issue.record("opening a newer schema should throw")
        } catch let error as DatabaseError {
            #expect(error == .newerSchema(found: 99, supported: SQLiteListenStore.schemaVersion))
        }

        #expect(try database.userVersion() == 99)
        #expect(database.backupCount() == 0)
    }
}
