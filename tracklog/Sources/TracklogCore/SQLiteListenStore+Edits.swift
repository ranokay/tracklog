import Foundation
import SQLite3

// MARK: - Simple edits

extension SQLiteListenStore {
    public func edits() async throws -> [SimpleEditRule] {
        let handle = try database()
        let statement = try prepare(
            handle,
            """
            SELECT id, match_track, match_artist, match_album, match_album_artist,
                   replacement_track, replacement_artist, replacement_album,
                   replacement_album_artist, saved_at
            FROM simple_edits
            """,
        )
        defer { sqlite3_finalize(statement) }

        var rules: [SimpleEditRule] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                rules.append(readSimpleEdit(statement))
            case SQLITE_DONE:
                return SimpleEditRule.sortedForApplication(rules)
            default:
                throw DatabaseError.sqlite(errorMessage(handle))
            }
        }
    }

    @discardableResult
    public func save(_ rule: SimpleEditRule) async throws -> SimpleEditRule {
        if let error = rule.validationError {
            throw error
        }

        let handle = try database()
        let key = rule.matchKey

        // Editing a rule's match tuple means the old row must not survive
        // beside the replacement. If the tuple already belongs to another rule,
        // that rule is the one this save replaces. The write happens before
        // the cleanup so a failed insert cannot lose the rule being edited.
        let supersededID: Int64? = if let id = rule.id,
                                      let current = try matchKey(for: id, handle: handle),
                                      current != key {
            id
        } else {
            nil
        }

        let statement = try prepare(
            handle,
            """
            INSERT INTO simple_edits (
                match_key, match_track, match_artist, match_album, match_album_artist,
                replacement_track, replacement_artist, replacement_album,
                replacement_album_artist, saved_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(match_key) DO UPDATE SET
                match_track = excluded.match_track,
                match_artist = excluded.match_artist,
                match_album = excluded.match_album,
                match_album_artist = excluded.match_album_artist,
                replacement_track = excluded.replacement_track,
                replacement_artist = excluded.replacement_artist,
                replacement_album = excluded.replacement_album,
                replacement_album_artist = excluded.replacement_album_artist,
                saved_at = excluded.saved_at
            """,
        )
        defer { sqlite3_finalize(statement) }

        try bind(key, at: 1, in: statement)
        try bind(rule.match.track, at: 2, in: statement)
        try bind(rule.match.artist, at: 3, in: statement)
        try bind(rule.match.album, at: 4, in: statement)
        try bind(rule.match.albumArtist, at: 5, in: statement)
        try bind(rule.replacement.track, at: 6, in: statement)
        try bind(rule.replacement.artist, at: 7, in: statement)
        try bind(rule.replacement.album, at: 8, in: statement)
        try bind(rule.replacement.albumArtist, at: 9, in: statement)
        sqlite3_bind_double(statement, 10, rule.savedAt.timeIntervalSince1970)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.sqlite(errorMessage(handle))
        }
        if let supersededID {
            try deleteEdit(id: supersededID, handle: handle)
        }
        guard let stored = try simpleEdit(matchKey: key, handle: handle) else {
            throw DatabaseError.sqlite("the saved rule could not be read back")
        }
        return stored
    }

    public func deleteEdit(id: Int64) async throws {
        try deleteEdit(id: id, handle: database())
    }

    // MARK: - Helpers

    private func deleteEdit(id: Int64, handle: OpaquePointer) throws {
        let statement = try prepare(handle, "DELETE FROM simple_edits WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, id)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.sqlite(errorMessage(handle))
        }
    }

    private func matchKey(for id: Int64, handle: OpaquePointer) throws -> String? {
        let statement = try prepare(handle, "SELECT match_key FROM simple_edits WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, id)
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return text(statement, 0)
        case SQLITE_DONE:
            return nil
        default:
            throw DatabaseError.sqlite(errorMessage(handle))
        }
    }

    private func simpleEdit(matchKey: String, handle: OpaquePointer) throws -> SimpleEditRule? {
        let statement = try prepare(
            handle,
            """
            SELECT id, match_track, match_artist, match_album, match_album_artist,
                   replacement_track, replacement_artist, replacement_album,
                   replacement_album_artist, saved_at
            FROM simple_edits
            WHERE match_key = ?
            """,
        )
        defer { sqlite3_finalize(statement) }
        try bind(matchKey, at: 1, in: statement)
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return readSimpleEdit(statement)
        case SQLITE_DONE:
            return nil
        default:
            throw DatabaseError.sqlite(errorMessage(handle))
        }
    }

    private func readSimpleEdit(_ statement: OpaquePointer) -> SimpleEditRule {
        SimpleEditRule(
            id: sqlite3_column_int64(statement, 0),
            match: SimpleEditRule.Match(
                track: optionalText(statement, 1),
                artist: optionalText(statement, 2),
                album: optionalText(statement, 3),
                albumArtist: optionalText(statement, 4),
            ),
            replacement: SimpleEditRule.Replacement(
                track: optionalText(statement, 5),
                artist: optionalText(statement, 6),
                album: optionalText(statement, 7),
                albumArtist: optionalText(statement, 8),
            ),
            savedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 9)),
        )
    }

    private func optionalText(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return text(statement, index)
    }

    private func bind(_ value: String?, at index: Int32, in statement: OpaquePointer) throws {
        if let value {
            try bind(value, at: index, in: statement)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }
}
