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
        ]
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
