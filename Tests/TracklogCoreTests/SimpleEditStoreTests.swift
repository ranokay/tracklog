import Foundation
import Testing
@testable import TracklogCore

@Suite("Simple edit store")
struct SimpleEditStoreTests {
    private let base = Date(timeIntervalSince1970: 1_000_000)

    @Test func savesAndReadsBackEveryField() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let original = simpleEditRule(
            match: .init(track: "Song", artist: "Artist", album: "Album", albumArtist: "Album Artist"),
            replace: .init(track: "Fixed Song", artist: "Fixed Artist", album: "", albumArtist: "Fixed Album Artist"),
        )

        let saved = try await store.save(original)
        let loaded = try await store.edits()

        #expect(saved.id != nil)
        #expect(loaded == [saved])
        #expect(loaded.first?.match == original.match)
        #expect(loaded.first?.replacement == original.replacement)
        #expect(loaded.first?.savedAt == original.savedAt)
    }

    @Test func disabledFieldsRoundTripAsWildcardsAndNoOps() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let saved = try await store.save(
            simpleEditRule(match: .init(track: "Song"), replace: .init(album: "Fixed Album")),
        )

        let loaded = try #require(try await store.edits().first)

        #expect(loaded == saved)
        #expect(loaded.match.artist == nil)
        #expect(loaded.match.album == nil)
        #expect(loaded.match.albumArtist == nil)
        #expect(loaded.replacement.track == nil)
        #expect(loaded.replacement.artist == nil)
        #expect(loaded.replacement.albumArtist == nil)
    }

    @Test func savingTheSameActiveMatchTupleReplacesTheRule() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let first = try await store.save(
            simpleEditRule(match: .init(track: "Song", artist: "Artist"), replace: .init(album: "Old Album")),
        )

        let replacement = try await store.save(
            simpleEditRule(
                match: .init(track: "  song ", artist: "ARTIST"),
                replace: .init(artist: "Fixed Artist", album: "New Album"),
                savedAt: base.addingTimeInterval(10),
            ),
        )

        let loaded = try await store.edits()

        #expect(loaded.count == 1)
        #expect(loaded.first?.id == first.id)
        #expect(loaded.first?.match == replacement.match)
        #expect(loaded.first?.replacement.album == "New Album")
        #expect(loaded.first?.replacement.artist == "Fixed Artist")
        #expect(loaded.first?.savedAt == replacement.savedAt)
    }

    @Test func anInactiveFieldMakesANewMatchTuple() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        _ = try await store.save(simpleEditRule(match: .init(track: "Song"), replace: .init(album: "One")))
        _ = try await store.save(
            simpleEditRule(match: .init(track: "Song", artist: "Artist"), replace: .init(album: "Two")),
        )
        _ = try await store.save(
            simpleEditRule(match: .init(track: "Song", album: ""), replace: .init(album: "Three")),
        )

        #expect(try await store.edits().count == 3)
    }

    @Test func rulesReadInApplicationOrder() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        _ = try await store.save(
            simpleEditRule(match: .init(track: "Song"), replace: .init(album: "Broad"), savedAt: base.addingTimeInterval(30)),
        )
        _ = try await store.save(
            simpleEditRule(
                match: .init(track: "Song", artist: "Artist"),
                replace: .init(album: "Older"),
                savedAt: base.addingTimeInterval(10),
            ),
        )
        _ = try await store.save(
            simpleEditRule(
                match: .init(track: "Song", album: "Album"),
                replace: .init(album: "Newer"),
                savedAt: base.addingTimeInterval(20),
            ),
        )

        let loaded = try await store.edits()

        #expect(loaded.map(\.replacement.album) == ["Newer", "Older", "Broad"])
    }

    @Test func editingTheMatchTupleReplacesTheEditedRule() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let first = try await store.save(
            simpleEditRule(match: .init(track: "Song"), replace: .init(album: "One")),
        )

        let edited = try await store.save(
            simpleEditRule(id: first.id, match: .init(album: "Album"), replace: .init(album: "Two")),
        )
        let loaded = try await store.edits()

        #expect(loaded == [edited])
        #expect(loaded.first?.match == .init(album: "Album"))
        #expect(loaded.first?.replacement.album == "Two")
    }

    @Test func deletingARuleRemovesIt() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let saved = try #require(
            try await store.save(simpleEditRule(match: .init(track: "Song"), replace: .init(album: "One"))),
        )

        try await store.deleteEdit(id: saved.id ?? -1)

        #expect(try await store.edits().isEmpty)
    }

    @Test func rulesSurviveAReopen() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let saved = try await store.save(
            simpleEditRule(match: .init(track: "Song"), replace: .init(album: "One"), savedAt: base.addingTimeInterval(5)),
        )
        await store.close()

        let reopened = try SQLiteListenStore(url: database.url)

        #expect(try await reopened.edits() == [saved])
    }

    @Test func upgradingFromSchemaTwoKeepsHistoryAndAddsEdits() async throws {
        let database = try TemporaryDatabase()
        let versionTwo = Array(SQLiteListenStore.schemaMigrations.prefix(2))
        let old = try SQLiteListenStore(url: database.url, migrations: versionTwo)
        let metadata = ListenMetadata(title: "Song", artist: "Artist")
        let stored = try database.insertLegacyListen(
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
        await old.close()
        #expect(try database.userVersion() == 2)

        let upgraded = try SQLiteListenStore(url: database.url)

        #expect(try await upgraded.userVersion() == SQLiteListenStore.schemaVersion)
        #expect(try await upgraded.recent(limit: 10) == [stored])
        #expect(try await upgraded.edits().isEmpty)
        #expect(database.backupCount() == 1)
    }

    @Test func refusesRulesThatCannotApply() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)

        await #expect(throws: SimpleEditRuleValidationError.noMatchFields) {
            _ = try await store.save(simpleEditRule(match: .init(), replace: .init(album: "One")))
        }
        await #expect(throws: SimpleEditRuleValidationError.noReplacements) {
            _ = try await store.save(simpleEditRule(match: .init(track: "Song"), replace: .init()))
        }
        await #expect(throws: SimpleEditRuleValidationError.cannotClearTrack) {
            _ = try await store.save(
                simpleEditRule(match: .init(track: "Song"), replace: .init(track: "", artist: "Artist")),
            )
        }
        await #expect(throws: SimpleEditRuleValidationError.cannotClearArtist) {
            _ = try await store.save(
                simpleEditRule(match: .init(artist: "Artist"), replace: .init(artist: "  ")),
            )
        }

        #expect(try await store.edits().isEmpty)
    }
}
