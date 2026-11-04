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

    // MARK: - Track history

    /// The full count and first listen for one local track key. This is the
    /// full scan the summary needs; it runs on this connection, never on the
    /// writer actor.
    func trackHistorySummary(matching key: String) async throws -> TrackHistorySummary {
        let scan = try await trackHistoryScan(
            matching: key,
            pageBefore: nil,
            pageLimit: 0,
            needsSummary: true,
        )
        return TrackHistorySummary(count: scan.count, firstListenedAt: scan.firstListenedAt)
    }

    /// One page of that track, newest first. The scan stops once the page is
    /// full; a page request never computes the summary.
    func trackHistoryPage(
        matching key: String,
        limit: Int,
        before cursor: ListenCursor?,
    ) async throws -> [Listen] {
        guard limit > 0 else { return [] }
        let scan = try await trackHistoryScan(
            matching: key,
            pageBefore: cursor,
            pageLimit: limit,
            needsSummary: false,
        )
        return scan.page
    }

    private struct TrackHistoryScan {
        var page: [Listen] = []
        var count = 0
        var firstListenedAt: Date?
    }

    // swiftlint:disable:next cyclomatic_complexity
    private func trackHistoryScan(
        matching key: String,
        pageBefore cursor: ListenCursor?,
        pageLimit: Int,
        needsSummary: Bool,
    ) async throws -> TrackHistoryScan {
        guard !isClosed else {
            throw DatabaseError.open("the chart reader is closed")
        }
        let handle = try openReadOnly()
        defer { sqlite3_close(handle) }

        try execute(handle, "BEGIN DEFERRED")
        do {
            let statement = try prepare(
                handle,
                """
                SELECT id, raw_title, raw_artist, raw_album, raw_album_artist,
                       title, artist, album, album_artist, bundle_id,
                       duration, played_duration, started_at, captured_at, artwork_hash
                FROM listens
                ORDER BY started_at DESC, id DESC
                """,
            )
            defer { sqlite3_finalize(statement) }

            var scan = TrackHistoryScan()
            var rowIndex = 0
            while true {
                switch sqlite3_step(statement) {
                case SQLITE_ROW:
                    let startedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 12))
                    let rowID = sqlite3_column_int64(statement, 0)
                    let rowKey = LocalTrackIdentity.key(
                        title: text(statement, 5),
                        artist: text(statement, 6),
                    )
                    if rowKey == key {
                        if needsSummary {
                            scan.count += 1
                            scan.firstListenedAt = startedAt
                        }
                        if pageLimit > 0, scan.page.count < pageLimit,
                           cursor == nil || isOlder(startedAt: startedAt, id: rowID, than: cursor) {
                            scan.page.append(readListen(statement))
                        }
                    }
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
                    // A page request owns no summary, so it can stop as soon
                    // as the page is full. A summary request scans the whole
                    // history.
                    if !needsSummary, pageLimit > 0, scan.page.count == pageLimit {
                        try checkOwnership()
                        try execute(handle, "COMMIT")
                        return scan
                    }
                case SQLITE_DONE:
                    try checkOwnership()
                    try execute(handle, "COMMIT")
                    return scan
                default:
                    throw DatabaseError.sqlite(errorMessage(handle))
                }
            }
        } catch {
            try? execute(handle, "ROLLBACK")
            throw error
        }
    }

    private func isOlder(startedAt: Date, id: Int64, than cursor: ListenCursor?) -> Bool {
        guard let cursor else { return true }
        if startedAt != cursor.startedAt {
            return startedAt < cursor.startedAt
        }
        return id < cursor.id
    }

    private func readListen(_ statement: OpaquePointer) -> Listen {
        Listen(
            id: sqlite3_column_int64(statement, 0),
            raw: ListenMetadata(
                title: text(statement, 1),
                artist: text(statement, 2),
                album: text(statement, 3),
                albumArtist: text(statement, 4),
            ),
            processed: ListenMetadata(
                title: text(statement, 5),
                artist: text(statement, 6),
                album: text(statement, 7),
                albumArtist: text(statement, 8),
            ),
            bundleID: text(statement, 9),
            duration: sqlite3_column_double(statement, 10),
            playedDuration: sqlite3_column_double(statement, 11),
            startedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 12)),
            capturedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 13)),
            artworkHash: sqlite3_column_type(statement, 14) == SQLITE_NULL
                ? nil
                : text(statement, 14),
        )
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
