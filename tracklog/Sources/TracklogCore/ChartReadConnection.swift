import Foundation
import SQLite3

/// A dedicated read-only SQLite reader for local chart aggregation. Each
/// request owns its own connection and transaction, so overlapping selections
/// and a close cannot share statements or transaction state. The reader yields
/// often enough to observe cancellation and stops using a connection only
/// after its own defer closes it.
actor ChartReadConnection {
    private let url: URL
    private var isClosed = false
    /// Installed only by the focused occupancy test; the production
    /// composition leaves it nil.
    private var rowObserver: (@Sendable (Int) async -> Void)?

    init(url: URL) {
        self.url = url
    }

    func close() {
        isClosed = true
    }

    /// A test seam that lets a scan pause at a row boundary. Production
    /// never installs one.
    func setRowObserver(_ observer: (@Sendable (Int) async -> Void)?) {
        rowObserver = observer
    }

    func localChart(
        type: ChartType,
        window: LocalChartWindow,
        limit: Int,
    ) async throws -> LocalChartAggregate {
        guard !isClosed else {
            throw DatabaseError.open("the chart reader is closed")
        }
        let handle = try openReadOnly()
        defer { sqlite3_close(handle) }

        try execute(handle, "BEGIN DEFERRED")
        do {
            let filter = window.range == nil ? "" : "WHERE started_at >= ? AND started_at < ?"
            let statement = try prepare(
                handle,
                """
                SELECT title, artist, album, album_artist, artwork_hash
                FROM listens
                \(filter)
                ORDER BY started_at ASC, id ASC
                """,
            )
            defer { sqlite3_finalize(statement) }
            if let range = window.range {
                sqlite3_bind_double(statement, 1, range.lowerBound.timeIntervalSince1970)
                sqlite3_bind_double(statement, 2, range.upperBound.timeIntervalSince1970)
            }

            var aggregator = LocalChartAggregator(type: type)
            var rowIndex = 0
            while true {
                switch sqlite3_step(statement) {
                case SQLITE_ROW:
                    aggregator.add(
                        title: text(statement, 0),
                        artist: text(statement, 1),
                        album: text(statement, 2),
                        albumArtist: text(statement, 3),
                        artworkHash: sqlite3_column_type(statement, 4) == SQLITE_NULL
                            ? nil
                            : text(statement, 4),
                    )
                    rowIndex += 1
                    if rowIndex % 64 == 0 {
                        try checkOwnership()
                        await Task.yield()
                        try checkOwnership()
                        if let observer = rowObserver {
                            await observer(rowIndex)
                            try checkOwnership()
                        }
                    }
                case SQLITE_DONE:
                    try checkOwnership()
                    try execute(handle, "COMMIT")
                    return aggregator.finish(limit: limit)
                default:
                    throw DatabaseError.sqlite(errorMessage(handle))
                }
            }
        } catch {
            try? execute(handle, "ROLLBACK")
            throw error
        }
    }

    private func checkOwnership() throws {
        if Task.isCancelled || isClosed {
            throw CancellationError()
        }
    }

    private func openReadOnly() throws -> OpaquePointer {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if let handle {
                sqlite3_close(handle)
            }
            throw DatabaseError.open(message)
        }
        sqlite3_busy_timeout(handle, 1_000)
        return handle
    }

    private func execute(_ handle: OpaquePointer, _ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &message) == SQLITE_OK else {
            let error = message.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(message)
            throw DatabaseError.sqlite(error)
        }
    }

    private func prepare(_ handle: OpaquePointer, _ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw DatabaseError.sqlite(errorMessage(handle))
        }
        return statement
    }

    private func text(_ statement: OpaquePointer, _ index: Int32) -> String {
        sqlite3_column_text(statement, index).map { String(cString: $0) } ?? ""
    }

    private func errorMessage(_ handle: OpaquePointer) -> String {
        String(cString: sqlite3_errmsg(handle))
    }
}
