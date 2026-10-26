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
        ]
    }
}
