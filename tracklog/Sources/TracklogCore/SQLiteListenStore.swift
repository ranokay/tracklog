import Foundation
import SQLite3

public enum DatabaseError: Error, Equatable, CustomStringConvertible {
    case open(String)
    case sqlite(String)
    case newerSchema(found: Int, supported: Int)
    case migrationFailed(version: Int, message: String)

    public var description: String {
        switch self {
        case .open(let message):
            "the database could not be opened: \(message)"
        case .sqlite(let message):
            "SQLite reported: \(message)"
        case .newerSchema(let found, let supported):
            "the database was written by a newer Tracklog (schema \(found); this build understands \(supported))"
        case .migrationFailed(let version, let message):
            "migration \(version) failed: \(message)"
        }
    }
}

/// One SQLite file in the droplet's container: local history, versioned
/// migrations, and the durable duplicate key.
public actor SQLiteListenStore: ListenStore {
    public static let schemaVersion = 1

    /// A migration's closure runs synchronously inside `open`, before the
    /// actor is shared, so sending it is safe even though the closure is not
    /// `Sendable` itself.
    public struct Migration: @unchecked Sendable {
        public let version: Int
        let apply: (OpaquePointer) throws -> Void

        init(version: Int, apply: @escaping (OpaquePointer) throws -> Void) {
            self.version = version
            self.apply = apply
        }
    }

    /// Computed rather than stored: the closures run once during `open`,
    /// before the actor is shared, and are not `Sendable`.
    static var schemaMigrations: [Migration] {
        [
            Migration(version: 1) { handle in
                try execute(
                    handle,
                    """
                    CREATE TABLE listens (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        raw_title TEXT NOT NULL,
                        raw_artist TEXT NOT NULL,
                        raw_album TEXT NOT NULL,
                        raw_album_artist TEXT NOT NULL,
                        title TEXT NOT NULL,
                        artist TEXT NOT NULL,
                        album TEXT NOT NULL,
                        album_artist TEXT NOT NULL,
                        bundle_id TEXT NOT NULL,
                        duration REAL NOT NULL,
                        played_duration REAL NOT NULL,
                        started_at REAL NOT NULL,
                        captured_at REAL NOT NULL,
                        dedup_key TEXT NOT NULL UNIQUE
                    );
                    CREATE INDEX listens_started_at ON listens (started_at DESC, id DESC);
                    """
                )
            },
        ]
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    /// The connection is only touched inside the actor, and by `deinit` once
    /// no other reference can reach it.
    nonisolated(unsafe) private var db: OpaquePointer?
    private let url: URL

    public init(url: URL) throws {
        try self.init(url: url, migrations: Self.schemaMigrations)
    }

    init(url: URL, migrations: [Migration]) throws {
        self.url = url
        self.db = try Self.open(url: url, migrations: migrations)
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    public func insert(_ listen: Listen) async throws -> Listen? {
        let handle = try database()
        let statement = try prepare(
            handle,
            """
            INSERT OR IGNORE INTO listens (
                raw_title, raw_artist, raw_album, raw_album_artist,
                title, artist, album, album_artist,
                bundle_id, duration, played_duration, started_at, captured_at, dedup_key
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        )
        defer { sqlite3_finalize(statement) }

        let fields = [
            listen.raw.title, listen.raw.artist, listen.raw.album, listen.raw.albumArtist,
            listen.processed.title, listen.processed.artist, listen.processed.album,
            listen.processed.albumArtist, listen.bundleID,
        ]
        for (offset, value) in fields.enumerated() {
            try bind(value, at: Int32(offset + 1), in: statement)
        }
        sqlite3_bind_double(statement, 10, listen.duration)
        sqlite3_bind_double(statement, 11, listen.playedDuration)
        sqlite3_bind_double(statement, 12, listen.startedAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 13, listen.capturedAt.timeIntervalSince1970)
        try bind(listen.dedupKey, at: 14, in: statement)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.sqlite(errorMessage(handle))
        }
        guard sqlite3_changes(handle) > 0 else { return nil }
        return listen.stored(withID: sqlite3_last_insert_rowid(handle))
    }

    public func recent(limit: Int) async throws -> [Listen] {
        guard limit > 0 else { return [] }
        let handle = try database()
        let statement = try prepare(
            handle,
            """
            SELECT id, raw_title, raw_artist, raw_album, raw_album_artist,
                   title, artist, album, album_artist, bundle_id,
                   duration, played_duration, started_at, captured_at
            FROM listens
            ORDER BY started_at DESC, id DESC
            LIMIT ?
            """
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(limit))

        var listens: [Listen] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                listens.append(
                    Listen(
                        id: sqlite3_column_int64(statement, 0),
                        raw: ListenMetadata(
                            title: text(statement, 1),
                            artist: text(statement, 2),
                            album: text(statement, 3),
                            albumArtist: text(statement, 4)
                        ),
                        processed: ListenMetadata(
                            title: text(statement, 5),
                            artist: text(statement, 6),
                            album: text(statement, 7),
                            albumArtist: text(statement, 8)
                        ),
                        bundleID: text(statement, 9),
                        duration: sqlite3_column_double(statement, 10),
                        playedDuration: sqlite3_column_double(statement, 11),
                        startedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 12)),
                        capturedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 13))
                    )
                )
            case SQLITE_DONE:
                return listens
            default:
                throw DatabaseError.sqlite(errorMessage(handle))
            }
        }
    }

    // MARK: - Lifecycle

    public func close() async {
        if let db {
            sqlite3_close(db)
            self.db = nil
        }
    }

    // MARK: - Introspection for the migration tests

    func userVersion() throws -> Int {
        try Self.intValue(try database(), "PRAGMA user_version")
    }

    func foreignKeysEnabled() throws -> Bool {
        try Self.intValue(try database(), "PRAGMA foreign_keys") == 1
    }

    // MARK: - Opening and migrating

    private static func open(url: URL, migrations: [Migration]) throws -> OpaquePointer {
        let existed = FileManager.default.fileExists(atPath: url.path)
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if let handle { sqlite3_close(handle) }
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
            formatOptions: [.withInternetDateTime, .withFractionalSeconds]
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

    private func database() throws -> OpaquePointer {
        guard let db else { throw DatabaseError.open("the database is closed") }
        return db
    }

    private func prepare(_ handle: OpaquePointer, _ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw DatabaseError.sqlite(errorMessage(handle))
        }
        return statement
    }

    private func bind(_ value: String, at index: Int32, in statement: OpaquePointer) throws {
        guard sqlite3_bind_text(statement, index, value, -1, Self.transient) == SQLITE_OK else {
            throw DatabaseError.sqlite("could not bind a text value")
        }
    }

    private func text(_ statement: OpaquePointer, _ index: Int32) -> String {
        sqlite3_column_text(statement, index).map { String(cString: $0) } ?? ""
    }

    private func errorMessage(_ handle: OpaquePointer) -> String {
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

    private static func intValue(_ handle: OpaquePointer, _ sql: String) throws -> Int {
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
