import SQLite3

extension SQLiteListenStore {
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
                    """,
                )
            },
            Migration(version: 2) { handle in
                try execute(
                    handle,
                    """
                    CREATE TABLE apps (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        bundle_id TEXT NOT NULL UNIQUE,
                        allowed INTEGER NOT NULL DEFAULT 0
                    );
                    """,
                )
                // The seed belongs to the schema that creates the table, so a
                // v1 database upgrading to v2 gets the same first-run defaults.
                // A later open never reruns it, so a denial survives.
                try seedDefaultApps(handle)
            },
            Migration(version: 3) { handle in
                try execute(
                    handle,
                    """
                    CREATE TABLE simple_edits (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        match_key TEXT NOT NULL UNIQUE,
                        match_track TEXT,
                        match_artist TEXT,
                        match_album TEXT,
                        match_album_artist TEXT,
                        replacement_track TEXT,
                        replacement_artist TEXT,
                        replacement_album TEXT,
                        replacement_album_artist TEXT,
                        saved_at REAL NOT NULL
                    );
                    """,
                )
            },
            Migration(version: 4) { handle in
                try execute(
                    handle,
                    """
                    CREATE TABLE blocks (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        match_key TEXT NOT NULL UNIQUE,
                        track TEXT NOT NULL DEFAULT '',
                        artist TEXT NOT NULL DEFAULT '',
                        album TEXT NOT NULL DEFAULT '',
                        album_artist TEXT NOT NULL DEFAULT '',
                        saved_at REAL NOT NULL
                    );
                    """,
                )
            },
            Migration(version: 5) { handle in
                try execute(
                    handle,
                    """
                    ALTER TABLE listens ADD COLUMN artwork_hash TEXT;
                    ALTER TABLE listens ADD COLUMN track_identity TEXT NOT NULL DEFAULT '';
                    CREATE TABLE artwork (
                        hash TEXT PRIMARY KEY,
                        data BLOB NOT NULL,
                        pixel_width INTEGER NOT NULL,
                        pixel_height INTEGER NOT NULL,
                        stored_at REAL NOT NULL
                    );
                    CREATE TABLE track_artwork (
                        track_identity TEXT PRIMARY KEY,
                        artwork_hash TEXT NOT NULL,
                        updated_at REAL NOT NULL,
                        FOREIGN KEY (artwork_hash) REFERENCES artwork (hash)
                    );
                    CREATE INDEX listens_artwork_hash ON listens (artwork_hash);
                    """,
                )
                try backfillTrackIdentities(handle)
            },
            Migration(version: 6) { handle in
                try execute(
                    handle,
                    """
                    CREATE TABLE connections (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        kind TEXT NOT NULL,
                        endpoint TEXT NOT NULL,
                        identity TEXT NOT NULL,
                        display_name TEXT NOT NULL,
                        enabled INTEGER NOT NULL DEFAULT 1,
                        auth_state TEXT NOT NULL,
                        created_at REAL NOT NULL,
                        last_used_at REAL NOT NULL,
                        UNIQUE (kind, endpoint)
                    );
                    CREATE TABLE connection_preferences (
                        key TEXT PRIMARY KEY,
                        value TEXT NOT NULL
                    );
                    """,
                )
            },
            Migration(version: 7) { handle in
                try execute(
                    handle,
                    """
                    CREATE TABLE deliveries (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        listen_id INTEGER NOT NULL REFERENCES listens (id) ON DELETE CASCADE,
                        connection_id INTEGER NOT NULL REFERENCES connections (id) ON DELETE CASCADE,
                        state TEXT NOT NULL,
                        attempts INTEGER NOT NULL DEFAULT 0,
                        last_attempt_at REAL,
                        next_attempt_at REAL,
                        last_error TEXT,
                        abandoned_reason TEXT,
                        delivered_at REAL,
                        service_reference TEXT,
                        UNIQUE (listen_id, connection_id)
                    );
                    CREATE INDEX deliveries_connection_due
                        ON deliveries (connection_id, state, next_attempt_at);
                    CREATE INDEX deliveries_next_attempt ON deliveries (next_attempt_at);
                    """,
                )
            },
            Migration(version: 8) { handle in
                // An unlinked connection is deleted, but its delivery rows must
                // survive so local history can still say which service will
                // never receive the listen. The service kind is denormalized
                // onto the row, and the connection is cleared rather than the
                // row cascading away.
                try execute(
                    handle,
                    """
                    CREATE TABLE deliveries_v8 (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        listen_id INTEGER NOT NULL REFERENCES listens (id) ON DELETE CASCADE,
                        connection_id INTEGER REFERENCES connections (id) ON DELETE SET NULL,
                        service_kind TEXT NOT NULL,
                        state TEXT NOT NULL,
                        attempts INTEGER NOT NULL DEFAULT 0,
                        last_attempt_at REAL,
                        next_attempt_at REAL,
                        last_error TEXT,
                        abandoned_reason TEXT,
                        delivered_at REAL,
                        service_reference TEXT,
                        UNIQUE (listen_id, connection_id)
                    );
                    INSERT INTO deliveries_v8 (
                        id, listen_id, connection_id, service_kind, state, attempts,
                        last_attempt_at, next_attempt_at, last_error, abandoned_reason,
                        delivered_at, service_reference
                    )
                    -- Every v7 row had a live connection: its foreign key
                    -- cascaded on delete. The join is therefore lossless, and
                    -- the service kind it copies is what history needs after
                    -- the connection is gone.
                    SELECT d.id, d.listen_id, d.connection_id, c.kind, d.state, d.attempts,
                           d.last_attempt_at, d.next_attempt_at, d.last_error, d.abandoned_reason,
                           d.delivered_at, d.service_reference
                    FROM deliveries d
                    JOIN connections c ON c.id = d.connection_id;
                    DROP TABLE deliveries;
                    ALTER TABLE deliveries_v8 RENAME TO deliveries;
                    CREATE INDEX deliveries_connection_due
                        ON deliveries (connection_id, state, next_attempt_at);
                    CREATE INDEX deliveries_next_attempt ON deliveries (next_attempt_at);
                    """,
                )
            },
            Migration(version: 9) { handle in
                // Local knowledge of a love or hate, keyed by the processed
                // track identity so a later listen of the same track reads the
                // same heart regardless of the source player.
                try execute(
                    handle,
                    """
                    CREATE TABLE feedback (
                        track_identity TEXT PRIMARY KEY,
                        score TEXT NOT NULL,
                        updated_at REAL NOT NULL
                    );
                    """,
                )
            },
            Migration(version: 10) { handle in
                // One bounded cache row per chart result. The key is the full
                // scope string; the columns exist so unlink and Custom pruning
                // can delete without decoding a payload.
                try execute(
                    handle,
                    """
                    CREATE TABLE chart_cache (
                        key TEXT PRIMARY KEY,
                        kind TEXT NOT NULL,
                        source TEXT NOT NULL,
                        service_kind TEXT NOT NULL DEFAULT '',
                        endpoint TEXT NOT NULL DEFAULT '',
                        account TEXT NOT NULL DEFAULT '',
                        chart_type TEXT NOT NULL DEFAULT '',
                        period TEXT NOT NULL DEFAULT '',
                        time_zone TEXT NOT NULL DEFAULT '',
                        window_start REAL NOT NULL DEFAULT -1,
                        window_end REAL NOT NULL DEFAULT -1,
                        schema_version INTEGER NOT NULL,
                        saved_at REAL NOT NULL,
                        payload BLOB NOT NULL
                    );
                    CREATE INDEX chart_cache_scope
                        ON chart_cache (source, endpoint, account);
                    CREATE INDEX chart_cache_selection
                        ON chart_cache (kind, chart_type, period);
                    """,
                )
            },
        ]
    }

    /// Legacy rows are keyed with the same Swift normalization the live
    /// artwork lookup uses, so non-ASCII case and tab/newline boundaries match.
    private static func backfillTrackIdentities(_ handle: OpaquePointer) throws {
        let rows = try readLegacyTrackIdentities(handle)
        guard !rows.isEmpty else { return }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            handle,
            "UPDATE listens SET track_identity = ? WHERE id = ?",
            -1,
            &statement,
            nil,
        ) == SQLITE_OK, let statement
        else {
            throw DatabaseError.sqlite("could not prepare the track identity backfill")
        }
        defer { sqlite3_finalize(statement) }

        for (id, identity) in rows {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            guard sqlite3_bind_text(statement, 1, identity, -1, Self.transient) == SQLITE_OK,
                  sqlite3_bind_int64(statement, 2, id) == SQLITE_OK,
                  sqlite3_step(statement) == SQLITE_DONE
            else {
                throw DatabaseError.sqlite(String(cString: sqlite3_errmsg(handle)))
            }
        }
    }

    private static func readLegacyTrackIdentities(
        _ handle: OpaquePointer,
    ) throws -> [(id: Int64, identity: String)] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            handle,
            "SELECT id, raw_title, raw_artist, raw_album, raw_album_artist FROM listens",
            -1,
            &statement,
            nil,
        ) == SQLITE_OK, let statement
        else {
            throw DatabaseError.sqlite("could not prepare the track identity read")
        }
        defer { sqlite3_finalize(statement) }

        var rows: [(Int64, String)] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                let metadata = ListenMetadata(
                    title: columnText(statement, 1),
                    artist: columnText(statement, 2),
                    album: columnText(statement, 3),
                    albumArtist: columnText(statement, 4),
                )
                rows.append((sqlite3_column_int64(statement, 0), metadata.identity))
            case SQLITE_DONE:
                return rows
            default:
                throw DatabaseError.sqlite(String(cString: sqlite3_errmsg(handle)))
            }
        }
    }

    private static func columnText(_ statement: OpaquePointer, _ index: Int32) -> String {
        sqlite3_column_text(statement, index).map { String(cString: $0) } ?? ""
    }
}

// MARK: - Test introspection

extension SQLiteListenStore {
    func userVersion() throws -> Int {
        try Self.intValue(database(), "PRAGMA user_version")
    }

    func foreignKeysEnabled() throws -> Bool {
        try Self.intValue(database(), "PRAGMA foreign_keys") == 1
    }
}
