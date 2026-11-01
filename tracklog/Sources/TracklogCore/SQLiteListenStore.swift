import Foundation
import SQLite3

public enum DatabaseError: Error, Equatable, CustomStringConvertible {
    case open(String)
    case unavailable(String)
    case sqlite(String)
    case newerSchema(found: Int, supported: Int)
    case migrationFailed(version: Int, message: String)

    public var description: String {
        switch self {
        case let .open(message):
            "the database could not be opened: \(message)"
        case let .unavailable(message):
            "the database is unavailable: \(message)"
        case let .sqlite(message):
            "SQLite reported: \(message)"
        case let .newerSchema(found, supported):
            "the database was written by a newer Tracklog (schema \(found); this build understands \(supported))"
        case let .migrationFailed(version, message):
            "migration \(version) failed: \(message)"
        }
    }
}

/// One SQLite file in the droplet's container: local history, connections,
/// versioned migrations, and the durable duplicate key.
public actor SQLiteListenStore: ListenStore, AppAllowlistStore, SimpleEditStore, BlockStore, ConnectionStore,
    ConnectionUnlinkStore, ConnectionReplaceStore, DeliveryStore, FeedbackStore {
    public static let schemaVersion = 10

    static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    /// The connection is only touched inside the actor, and by `deinit` once
    /// no other reference can reach it.
    private nonisolated(unsafe) var connection: OpaquePointer?
    private let url: URL
    /// The local chart scan's own read-only connection: a full-history read
    /// must not occupy the writer actor that capture and delivery use.
    let chartReader: ChartReadConnection?

    public init(url: URL) throws {
        try self.init(url: url, migrations: Self.schemaMigrations)
    }

    init(url: URL, migrations: [Migration]) throws {
        self.url = url
        connection = try Self.open(url: url, migrations: migrations)
        chartReader = try? ChartReadConnection(url: url)
    }

    deinit {
        if let connection {
            sqlite3_close(connection)
        }
    }

    public func page(limit: Int, before cursor: ListenCursor?) async throws -> [Listen] {
        guard limit > 0 else { return [] }
        let handle = try database()
        let filter = cursor == nil ? "" : "WHERE started_at < ? OR (started_at = ? AND id < ?)"
        let statement = try prepare(
            handle,
            """
            SELECT id, raw_title, raw_artist, raw_album, raw_album_artist,
                   title, artist, album, album_artist, bundle_id,
                   duration, played_duration, started_at, captured_at, artwork_hash
            FROM listens
            \(filter)
            ORDER BY started_at DESC, id DESC
            LIMIT ?
            """,
        )
        defer { sqlite3_finalize(statement) }

        var index: Int32 = 1
        if let cursor {
            let start = cursor.startedAt.timeIntervalSince1970
            sqlite3_bind_double(statement, index, start)
            index += 1
            sqlite3_bind_double(statement, index, start)
            index += 1
            sqlite3_bind_int64(statement, index, cursor.id)
            index += 1
        }
        sqlite3_bind_int(statement, index, Int32(clamping: limit))

        return try readListens(statement, handle: handle)
    }

    // MARK: - Lifecycle

    public func close() async {
        if let connection {
            sqlite3_close(connection)
            self.connection = nil
        }
        await chartReader?.close()
    }

    // MARK: - Opening and migrating

    private static func open(
        url: URL,
        migrations: [Migration],
    ) throws -> OpaquePointer {
        let existed = FileManager.default.fileExists(atPath: url.path)
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if let handle {
                sqlite3_close(handle)
            }
            throw DatabaseError.open(message)
        }

        do {
            try execute(handle, "PRAGMA foreign_keys = ON")
            guard try intValue(handle, "PRAGMA foreign_keys") == 1 else {
                throw DatabaseError.open("foreign keys could not be enabled")
            }

            // Read the version before any setting that can touch the file:
            // a database from a newer build must be refused untouched.
            let ordered = migrations.sorted { $0.version < $1.version }
            let supported = ordered.last?.version ?? 0
            let current = try intValue(handle, "PRAGMA user_version")
            guard current <= supported else {
                throw DatabaseError.newerSchema(found: current, supported: supported)
            }

            try execute(handle, "PRAGMA journal_mode = WAL")
            if current < supported {
                // A brand-new file has nothing worth preserving.
                if existed {
                    try backup(handle: handle, url: url)
                }
                try migrate(handle, from: current, using: ordered)
            }
            return handle
        } catch {
            sqlite3_close(handle)
            throw error
        }
    }

    private static func migrate(_ handle: OpaquePointer, from current: Int, using migrations: [Migration]) throws {
        let pending = migrations.filter { $0.version > current }
        var applying = current
        try execute(handle, "BEGIN IMMEDIATE")
        do {
            for migration in pending {
                applying = migration.version
                try migration.apply(handle)
            }
            if let target = pending.last?.version {
                try execute(handle, "PRAGMA user_version = \(target)")
            }
            try execute(handle, "COMMIT")
        } catch {
            try? execute(handle, "ROLLBACK")
            throw DatabaseError.migrationFailed(version: applying, message: "\(error)")
        }
    }

    private static func backup(handle: OpaquePointer, url: URL) throws {
        // Fold the WAL into the main file so one copy is a complete database.
        try execute(handle, "PRAGMA wal_checkpoint(TRUNCATE)")
        let stamp = ISO8601DateFormatter.string(
            from: Date(),
            timeZone: .gmt,
            formatOptions: [.withInternetDateTime, .withFractionalSeconds],
        )
        .replacingOccurrences(of: ":", with: "-")
        let name = "\(url.deletingPathExtension().lastPathComponent)-backup-\(stamp).sqlite"
        let destination = url.deletingLastPathComponent().appendingPathComponent(name)
        do {
            try FileManager.default.copyItem(at: url, to: destination)
        } catch {
            throw DatabaseError.open("could not copy the pre-migration backup: \(error)")
        }
    }

    // MARK: - SQLite helpers

    func database() throws -> OpaquePointer {
        guard let connection else { throw DatabaseError.open("the database is closed") }
        return connection
    }

    func prepare(_ handle: OpaquePointer, _ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw DatabaseError.sqlite(errorMessage(handle))
        }
        return statement
    }

    func bind(_ value: String, at index: Int32, in statement: OpaquePointer) throws {
        guard sqlite3_bind_text(statement, index, value, -1, Self.transient) == SQLITE_OK else {
            throw DatabaseError.sqlite("could not bind a text value")
        }
    }

    private func readListens(_ statement: OpaquePointer, handle: OpaquePointer) throws -> [Listen] {
        var listens: [Listen] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                listens.append(readListen(statement, offset: 0))
            case SQLITE_DONE:
                return listens
            default:
                throw DatabaseError.sqlite(errorMessage(handle))
            }
        }
    }

    /// Reads a listen from the columns starting at `offset`, so a query can
    /// put delivery columns in front of it.
    func readListen(_ statement: OpaquePointer, offset: Int32) -> Listen {
        Listen(
            id: sqlite3_column_int64(statement, offset),
            raw: ListenMetadata(
                title: text(statement, offset + 1),
                artist: text(statement, offset + 2),
                album: text(statement, offset + 3),
                albumArtist: text(statement, offset + 4),
            ),
            processed: ListenMetadata(
                title: text(statement, offset + 5),
                artist: text(statement, offset + 6),
                album: text(statement, offset + 7),
                albumArtist: text(statement, offset + 8),
            ),
            bundleID: text(statement, offset + 9),
            duration: sqlite3_column_double(statement, offset + 10),
            playedDuration: sqlite3_column_double(statement, offset + 11),
            startedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, offset + 12)),
            capturedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, offset + 13)),
            artworkHash: sqlite3_column_type(statement, offset + 14) == SQLITE_NULL
                ? nil
                : text(statement, offset + 14),
        )
    }

    func text(_ statement: OpaquePointer, _ index: Int32) -> String {
        sqlite3_column_text(statement, index).map { String(cString: $0) } ?? ""
    }

    func errorMessage(_ handle: OpaquePointer) -> String {
        String(cString: sqlite3_errmsg(handle))
    }

    static func execute(_ handle: OpaquePointer, _ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &message) == SQLITE_OK else {
            let error = message.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(message)
            throw DatabaseError.sqlite(error)
        }
    }

    static func intValue(_ handle: OpaquePointer, _ sql: String) throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw DatabaseError.sqlite("could not prepare \(sql)")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw DatabaseError.sqlite("no row for \(sql)")
        }
        return Int(sqlite3_column_int(statement, 0))
    }
}

// MARK: - Counting

public extension SQLiteListenStore {
    func count() async throws -> Int {
        try Self.intValue(database(), "SELECT COUNT(*) FROM listens")
    }

    func count(in range: Range<Date>) async throws -> Int {
        let handle = try database()
        let statement = try prepare(
            handle,
            "SELECT COUNT(*) FROM listens WHERE started_at >= ? AND started_at < ?",
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, range.lowerBound.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, range.upperBound.timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw DatabaseError.sqlite(errorMessage(handle))
        }
        return Int(sqlite3_column_int64(statement, 0))
    }
}
