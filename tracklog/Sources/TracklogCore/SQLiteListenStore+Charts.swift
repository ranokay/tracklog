import Foundation
import SQLite3

// MARK: - Exact local grouping

extension SQLiteListenStore: ChartStore {
    /// The scan runs on its own read-only connection, so the writer actor is
    /// free for capture, History and delivery while a large local read runs.
    public func localChart(
        type: ChartType,
        window: LocalChartWindow,
        limit: Int,
    ) async throws -> LocalChartAggregate {
        guard let chartReader else {
            throw DatabaseError.open("the local chart reader is unavailable")
        }
        return try await chartReader.localChart(type: type, window: window, limit: limit)
    }
}

// MARK: - Cache

public extension SQLiteListenStore {
    func chartCache(_ key: ChartCacheKey) async throws -> ChartCacheEntry? {
        let handle = try database()
        let statement = try prepare(
            handle,
            "SELECT saved_at, payload FROM chart_cache WHERE key = ? AND schema_version = ?",
        )
        defer { sqlite3_finalize(statement) }
        try bind(key.rawKey, at: 1, in: statement)
        sqlite3_bind_int(statement, 2, Int32(clamping: key.schemaVersion))
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let savedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
        guard let bytes = sqlite3_column_blob(statement, 1) else {
            return ChartCacheEntry(savedAt: savedAt, payload: Data())
        }
        let payload = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 1)))
        return ChartCacheEntry(savedAt: savedAt, payload: payload)
    }

    func saveChartCache(_ entry: ChartCacheEntry, for key: ChartCacheKey) async throws {
        let handle = try database()
        try Self.execute(handle, "BEGIN IMMEDIATE")
        do {
            try pruneStaleChartRows(handle)
            try pruneShadowedLocalRows(key: key, handle: handle)
            let statement = try prepare(
                handle,
                """
                INSERT INTO chart_cache (
                    key, kind, source, service_kind, endpoint, account, chart_type,
                    period, time_zone, window_start, window_end, schema_version,
                    saved_at, payload
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(key) DO UPDATE SET
                    saved_at = excluded.saved_at,
                    payload = excluded.payload
                """,
            )
            defer { sqlite3_finalize(statement) }
            try bind(key.rawKey, at: 1, in: statement)
            try bind(key.kind.rawValue, at: 2, in: statement)
            try bind(key.source.rawValue, at: 3, in: statement)
            try bind(key.serviceKind?.rawValue ?? "", at: 4, in: statement)
            try bind(key.endpoint, at: 5, in: statement)
            try bind(key.account, at: 6, in: statement)
            try bind(key.chartType?.rawValue ?? "", at: 7, in: statement)
            try bind(key.period.rawValue, at: 8, in: statement)
            try bind(key.timeZoneID, at: 9, in: statement)
            sqlite3_bind_double(statement, 10, key.windowStart?.timeIntervalSince1970 ?? -1)
            sqlite3_bind_double(statement, 11, key.windowEnd?.timeIntervalSince1970 ?? -1)
            sqlite3_bind_int(statement, 12, Int32(clamping: key.schemaVersion))
            sqlite3_bind_double(statement, 13, entry.savedAt.timeIntervalSince1970)
            entry.payload.withUnsafeBytes { bytes in
                _ = sqlite3_bind_blob(statement, 14, bytes.baseAddress, Int32(bytes.count), Self.transient)
            }
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DatabaseError.sqlite(errorMessage(handle))
            }
            try Self.execute(handle, "COMMIT")
        } catch {
            try? Self.execute(handle, "ROLLBACK")
            throw error
        }
    }

    func evictChartCaches(endpoint: String, account: String) async throws {
        let handle = try database()
        let statement = try prepare(
            handle,
            """
            DELETE FROM chart_cache
            WHERE source = 'service' AND endpoint = ? AND account = ?
            """,
        )
        defer { sqlite3_finalize(statement) }
        try bind(endpoint, at: 1, in: statement)
        try bind(account, at: 2, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.sqlite(errorMessage(handle))
        }
    }

    func pruneChartCaches() async throws {
        let handle = try database()
        try pruneStaleChartRows(handle)
        // A crash between the Custom pruning delete and its insert would
        // otherwise leave two Custom snapshots for one type.
        try Self.execute(
            handle,
            """
            DELETE FROM chart_cache
            WHERE source = 'local' AND kind = 'list' AND period = 'custom'
              AND rowid NOT IN (
                  SELECT MAX(rowid) FROM chart_cache
                  WHERE source = 'local' AND kind = 'list' AND period = 'custom'
                  GROUP BY chart_type
              )
            """,
        )
    }

    func clearLocalCustomChartCaches() async throws {
        let handle = try database()
        try Self.execute(
            handle,
            "DELETE FROM chart_cache WHERE source = 'local' AND period = 'custom'",
        )
    }

    private func pruneStaleChartRows(_ handle: OpaquePointer) throws {
        try Self.execute(
            handle,
            "DELETE FROM chart_cache WHERE schema_version <> \(ChartCacheSchema.version)",
        )
    }

    /// Local standard results are global to this Mac: exactly one snapshot per
    /// kind/type/period, even when the rolling window or time zone changed.
    /// Custom keeps exactly one snapshot per type.
    private func pruneShadowedLocalRows(key: ChartCacheKey, handle: OpaquePointer) throws {
        guard key.source == .local else { return }
        if key.period == .custom {
            let statement = try prepare(
                handle,
                """
                DELETE FROM chart_cache
                WHERE source = 'local' AND kind = ? AND period = 'custom'
                  AND chart_type = ? AND key <> ?
                """,
            )
            defer { sqlite3_finalize(statement) }
            try bind(key.kind.rawValue, at: 1, in: statement)
            try bind(key.chartType?.rawValue ?? "", at: 2, in: statement)
            try bind(key.rawKey, at: 3, in: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DatabaseError.sqlite(errorMessage(handle))
            }
        } else {
            let statement = try prepare(
                handle,
                """
                DELETE FROM chart_cache
                WHERE source = 'local' AND kind = ? AND chart_type = ? AND period = ?
                  AND key <> ?
                """,
            )
            defer { sqlite3_finalize(statement) }
            try bind(key.kind.rawValue, at: 1, in: statement)
            try bind(key.chartType?.rawValue ?? "", at: 2, in: statement)
            try bind(key.period.rawValue, at: 3, in: statement)
            try bind(key.rawKey, at: 4, in: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DatabaseError.sqlite(errorMessage(handle))
            }
        }
    }

    /// Used by the connection transaction: an unlink or identity replacement
    /// must not leave the old account's remote rows behind.
    func deleteRemoteChartCaches(
        endpoint: String,
        account: String,
        handle: OpaquePointer,
    ) throws {
        let statement = try prepare(
            handle,
            "DELETE FROM chart_cache WHERE source = 'service' AND endpoint = ? AND account = ?",
        )
        defer { sqlite3_finalize(statement) }
        try bind(endpoint, at: 1, in: statement)
        try bind(account, at: 2, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.sqlite(errorMessage(handle))
        }
    }
}

// MARK: - Test introspection

extension SQLiteListenStore {
    func chartCacheCount() throws -> Int {
        try Self.intValue(database(), "SELECT COUNT(*) FROM chart_cache")
    }

    func chartCachePayloads() throws -> [Data] {
        let handle = try database()
        let statement = try prepare(handle, "SELECT payload FROM chart_cache")
        defer { sqlite3_finalize(statement) }
        var payloads: [Data] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let bytes = sqlite3_column_blob(statement, 0) else { continue }
            payloads.append(Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0))))
        }
        return payloads
    }
}
