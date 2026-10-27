import Foundation
import SQLite3

// MARK: - Blocks

extension SQLiteListenStore {
    public func blocks() async throws -> [BlockRule] {
        let handle = try database()
        let statement = try prepare(
            handle,
            """
            SELECT id, track, artist, album, album_artist, saved_at
            FROM blocks
            """,
        )
        defer { sqlite3_finalize(statement) }

        var rules: [BlockRule] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                rules.append(readBlock(statement))
            case SQLITE_DONE:
                return BlockRule.sortedForEvaluation(rules)
            default:
                throw DatabaseError.sqlite(errorMessage(handle))
            }
        }
    }

    @discardableResult
    public func save(_ block: BlockRule) async throws -> BlockRule {
        if let error = block.validationError {
            throw error
        }

        let handle = try database()
        let key = block.matchKey

        // Editing a block's fields means the old row must not survive beside
        // the replacement. If the tuple already belongs to another block, that
        // block is the one this save replaces. The write happens before the
        // cleanup so a failed insert cannot lose the block being edited.
        let supersededID: Int64? = if let id = block.id,
                                      let current = try blockMatchKey(for: id, handle: handle),
                                      current != key {
            id
        } else {
            nil
        }

        let statement = try prepare(
            handle,
            """
            INSERT INTO blocks (match_key, track, artist, album, album_artist, saved_at)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(match_key) DO UPDATE SET
                track = excluded.track,
                artist = excluded.artist,
                album = excluded.album,
                album_artist = excluded.album_artist,
                saved_at = excluded.saved_at
            """,
        )
        defer { sqlite3_finalize(statement) }

        try bind(key, at: 1, in: statement)
        try bind(block.track, at: 2, in: statement)
        try bind(block.artist, at: 3, in: statement)
        try bind(block.album, at: 4, in: statement)
        try bind(block.albumArtist, at: 5, in: statement)
        sqlite3_bind_double(statement, 6, block.savedAt.timeIntervalSince1970)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.sqlite(errorMessage(handle))
        }
        if let supersededID {
            try deleteBlock(id: supersededID, handle: handle)
        }
        guard let stored = try storedBlock(matchKey: key, handle: handle) else {
            throw DatabaseError.sqlite("the saved block could not be read back")
        }
        return stored
    }

    public func deleteBlock(id: Int64) async throws {
        try deleteBlock(id: id, handle: database())
    }

    // MARK: - Helpers

    private func deleteBlock(id: Int64, handle: OpaquePointer) throws {
        let statement = try prepare(handle, "DELETE FROM blocks WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, id)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.sqlite(errorMessage(handle))
        }
    }

    private func blockMatchKey(for id: Int64, handle: OpaquePointer) throws -> String? {
        let statement = try prepare(handle, "SELECT match_key FROM blocks WHERE id = ?")
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

    private func storedBlock(matchKey: String, handle: OpaquePointer) throws -> BlockRule? {
        let statement = try prepare(
            handle,
            """
            SELECT id, track, artist, album, album_artist, saved_at
            FROM blocks
            WHERE match_key = ?
            """,
        )
        defer { sqlite3_finalize(statement) }
        try bind(matchKey, at: 1, in: statement)
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return readBlock(statement)
        case SQLITE_DONE:
            return nil
        default:
            throw DatabaseError.sqlite(errorMessage(handle))
        }
    }

    private func readBlock(_ statement: OpaquePointer) -> BlockRule {
        BlockRule(
            id: sqlite3_column_int64(statement, 0),
            track: text(statement, 1),
            artist: text(statement, 2),
            album: text(statement, 3),
            albumArtist: text(statement, 4),
            savedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
        )
    }
}
