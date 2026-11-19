import Foundation
import SQLite3

// MARK: - Feed navigation

extension SQLiteListenStore: HistoryNavigationStore, TrackHistoryStore {
    public func historyPosition(at date: Date) async throws -> HistoryPosition {
        let handle = try database()
        let statement = try prepare(
            handle,
            """
            SELECT started_at, id FROM listens
            WHERE started_at >= ?
            ORDER BY started_at ASC, id DESC
            LIMIT 1
            """,
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)

        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return .atCursor(
                ListenCursor(
                    startedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
                    id: sqlite3_column_int64(statement, 1),
                ),
            )
        case SQLITE_DONE:
            return .newest
        default:
            throw DatabaseError.sqlite(errorMessage(handle))
        }
    }

    public func page(limit: Int, endingAt cursor: ListenCursor) async throws -> [Listen] {
        guard limit > 0 else { return [] }
        let handle = try database()
        let statement = try prepare(
            handle,
            """
            SELECT \(Self.listenColumns)
            FROM listens
            WHERE started_at < ? OR (started_at = ? AND id <= ?)
            ORDER BY started_at DESC, id DESC
            LIMIT ?
            """,
        )
        defer { sqlite3_finalize(statement) }

        let start = cursor.startedAt.timeIntervalSince1970
        sqlite3_bind_double(statement, 1, start)
        sqlite3_bind_double(statement, 2, start)
        sqlite3_bind_int64(statement, 3, cursor.id)
        sqlite3_bind_int(statement, 4, Int32(clamping: limit))
        return try readListens(statement, handle: handle)
    }

    public func page(limit: Int, after cursor: ListenCursor) async throws -> [Listen] {
        guard limit > 0 else { return [] }
        let handle = try database()
        let statement = try prepare(
            handle,
            """
            SELECT \(Self.listenColumns)
            FROM listens
            WHERE started_at > ? OR (started_at = ? AND id > ?)
            ORDER BY started_at ASC, id ASC
            LIMIT ?
            """,
        )
        defer { sqlite3_finalize(statement) }

        let start = cursor.startedAt.timeIntervalSince1970
        sqlite3_bind_double(statement, 1, start)
        sqlite3_bind_double(statement, 2, start)
        sqlite3_bind_int64(statement, 3, cursor.id)
        sqlite3_bind_int(statement, 4, Int32(clamping: limit))
        // The scan walks upward to take the immediately newer rows; the feed
        // shows them newest first.
        return try Array(readListens(statement, handle: handle).reversed())
    }

    public func hasOlderListen(than cursor: ListenCursor) async throws -> Bool {
        try exists(
            "WHERE started_at < ? OR (started_at = ? AND id < ?)",
            cursor: cursor,
        )
    }

    public func hasNewerListen(than cursor: ListenCursor) async throws -> Bool {
        try exists(
            "WHERE started_at > ? OR (started_at = ? AND id > ?)",
            cursor: cursor,
        )
    }

    // MARK: - Track history

    public func trackHistorySummary(matching key: String) async throws -> TrackHistorySummary {
        try await chartReader.trackHistorySummary(matching: key)
    }

    public func trackHistoryPage(
        matching key: String,
        limit: Int,
        before cursor: ListenCursor?,
    ) async throws -> [Listen] {
        try await chartReader.trackHistoryPage(matching: key, limit: limit, before: cursor)
    }

    // MARK: - Helpers

    static let listenColumns = """
    id, raw_title, raw_artist, raw_album, raw_album_artist,
    title, artist, album, album_artist, bundle_id,
    duration, played_duration, started_at, captured_at, artwork_hash
    """

    private func exists(_ filter: String, cursor: ListenCursor) throws -> Bool {
        let handle = try database()
        let statement = try prepare(
            handle,
            "SELECT 1 FROM listens \(filter) LIMIT 1",
        )
        defer { sqlite3_finalize(statement) }
        let start = cursor.startedAt.timeIntervalSince1970
        sqlite3_bind_double(statement, 1, start)
        sqlite3_bind_double(statement, 2, start)
        sqlite3_bind_int64(statement, 3, cursor.id)
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return true
        case SQLITE_DONE:
            return false
        default:
            throw DatabaseError.sqlite(errorMessage(handle))
        }
    }
}
