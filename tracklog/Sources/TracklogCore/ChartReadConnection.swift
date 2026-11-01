import Foundation
import SQLite3

/// A dedicated read-only SQLite connection for local chart aggregation. It
/// keeps the full-history scan off the writer/capture actor, reads one
/// consistent WAL snapshot, and yields often enough to observe cancellation.
actor ChartReadConnection {
    private nonisolated(unsafe) var connection: OpaquePointer?
    private let url: URL
    /// Installed only by the focused occupancy test; the production
    /// composition leaves it nil.
    private var rowObserver: (@Sendable (Int) async -> Void)?

    init(url: URL) throws {
        self.url = url
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
        connection = handle
    }

    deinit {
        if let connection {
            sqlite3_close(connection)
        }
    }

    func close() {
        if let connection {
            sqlite3_close(connection)
            self.connection = nil
        }
    }

    /// A test seam that lets a scan pause at a row boundary. Production
    /// never installs one.
    func setRowObserver(_ observer: (@Sendable (Int) async -> Void)?) {
        rowObserver = observer
    }

    // swiftlint:disable:next cyclomatic_complexity
    func localChart(
        type: ChartType,
        window: LocalChartWindow,
        limit: Int,
    ) async throws -> LocalChartAggregate {
        guard let handle = connection else {
            throw DatabaseError.open("the chart reader is closed")
        }

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
                        if Task.isCancelled {
                            throw CancellationError()
                        }
                        await Task.yield()
                        if let observer = rowObserver {
                            await observer(rowIndex)
                        }
                    }
                case SQLITE_DONE:
                    if Task.isCancelled {
                        throw CancellationError()
                    }
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
