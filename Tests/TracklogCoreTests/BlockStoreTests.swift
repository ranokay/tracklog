import Foundation
import Testing
@testable import TracklogCore

@Suite("Block store")
struct BlockStoreTests {
    private let base = Date(timeIntervalSince1970: 1_000_000)

    @Test func savesAndReadsBackEveryField() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let original = blockRule(
            track: "Song",
            artist: "Artist",
            album: "Album",
            albumArtist: "Album Artist",
        )

        let saved = try await store.save(original)
        let loaded = try await store.blocks()

        #expect(saved.id != nil)
        #expect(loaded == [saved])
        #expect(loaded.first?.track == "Song")
        #expect(loaded.first?.artist == "Artist")
        #expect(loaded.first?.album == "Album")
        #expect(loaded.first?.albumArtist == "Album Artist")
        #expect(loaded.first?.savedAt == original.savedAt)
    }

    @Test func blankFieldsRoundTripAsWildcards() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)

        let saved = try await store.save(blockRule(track: "Song"))

        let loaded = try #require(try await store.blocks().first)
        #expect(loaded == saved)
        #expect(loaded.artist.isEmpty)
        #expect(loaded.album.isEmpty)
        #expect(loaded.albumArtist.isEmpty)
    }

    @Test func refusesAnAllBlankBlock() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)

        await #expect(throws: BlockRuleValidationError.noFields) {
            _ = try await store.save(blockRule(track: " ", artist: "\n"))
        }
        #expect(try await store.blocks().isEmpty)
    }

    @Test func savingTheSameFieldsReplacesTheBlock() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let first = try await store.save(blockRule(track: "Song", artist: "Artist"))

        let replacement = try await store.save(
            blockRule(
                track: "  song ",
                artist: "ARTIST",
                savedAt: base.addingTimeInterval(10),
            ),
        )

        let loaded = try await store.blocks()

        #expect(loaded.count == 1)
        #expect(loaded.first?.id == first.id)
        #expect(loaded.first?.savedAt == replacement.savedAt)
    }

    @Test func editingTheFieldsReplacesTheEditedBlock() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let first = try await store.save(blockRule(track: "Song"))

        let edited = try await store.save(
            blockRule(id: first.id, album: "Album"),
        )
        let loaded = try await store.blocks()

        #expect(loaded == [edited])
        #expect(loaded.first?.track.isEmpty == true)
        #expect(loaded.first?.album == "Album")
    }

    @Test func deletingABlockRemovesIt() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let saved = try await store.save(blockRule(track: "Song"))

        try await store.deleteBlock(id: saved.id ?? -1)

        #expect(try await store.blocks().isEmpty)
    }

    @Test func blocksReadInEvaluationOrder() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        _ = try await store.save(
            blockRule(artist: "Artist", savedAt: base.addingTimeInterval(30)),
        )
        _ = try await store.save(
            blockRule(track: "Song", artist: "Artist", savedAt: base.addingTimeInterval(10)),
        )
        _ = try await store.save(
            blockRule(track: "Song", savedAt: base.addingTimeInterval(20)),
        )

        let loaded = try await store.blocks()

        #expect(loaded.map(\.activeCount) == [2, 1, 1])
        #expect(loaded.first?.track == "Song")
        #expect(loaded.first?.artist == "Artist")
    }

    @Test func blocksSurviveAReopen() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let saved = try await store.save(
            blockRule(track: "Song", savedAt: base.addingTimeInterval(5)),
        )
        await store.close()

        let reopened = try SQLiteListenStore(url: database.url)

        #expect(try await reopened.blocks() == [saved])
    }

    @Test func upgradingFromSchemaThreeKeepsHistoryAndEditsAndAddsBlocks() async throws {
        let database = try TemporaryDatabase()
        let versionThree = Array(SQLiteListenStore.schemaMigrations.prefix(3))
        let old = try SQLiteListenStore(url: database.url, migrations: versionThree)
        let metadata = ListenMetadata(title: "Song", artist: "Artist")
        let storedListen = try database.insertLegacyListen(
            Listen(
                raw: metadata,
                processed: metadata,
                bundleID: "com.apple.Music",
                duration: 30,
                playedDuration: 30,
                startedAt: base,
                capturedAt: base.addingTimeInterval(30),
            ),
        )
        let storedEdit = try await old.save(
            simpleEditRule(match: .init(track: "Song"), replace: .init(album: "Fixed")),
        )
        await old.close()
        #expect(try database.userVersion() == 3)

        let upgraded = try SQLiteListenStore(url: database.url)

        #expect(try await upgraded.userVersion() == SQLiteListenStore.schemaVersion)
        #expect(try await upgraded.recent(limit: 10) == [storedListen])
        #expect(try await upgraded.edits() == [storedEdit])
        #expect(try await upgraded.blocks().isEmpty)
        #expect(database.backupCount() == 1)
    }
}
