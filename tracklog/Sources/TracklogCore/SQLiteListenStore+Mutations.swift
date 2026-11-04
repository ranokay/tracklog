import Foundation
import SQLite3

// MARK: - Local history mutation

extension SQLiteListenStore: ListenMutationStore {
    /// Writes an edit, an optional simple-edit rule and the local chart cache
    /// invalidation in one transaction. Delivery rows are deliberately
    /// untouched: a waiting or retrying target reads the corrected row on its
    /// next attempt.
    public func editListen(
        id: Int64,
        to metadata: ListenMetadata,
        remembering rule: SimpleEditRule?,
    ) async throws -> ListenEditResult {
        let trimmed = metadata.trimmedForEdit
        guard trimmed.isValidEditedMetadata else {
            throw ListenMutationError.invalidMetadata
        }

        let handle = try database()
        try Self.execute(handle, "BEGIN IMMEDIATE")
        do {
            guard let original = try listenRow(id: id, handle: handle) else {
                throw ListenMutationError.notFound
            }
            let statement = try prepare(
                handle,
                """
                UPDATE listens
                SET title = ?, artist = ?, album = ?, album_artist = ?
                WHERE id = ?
                """,
            )
            defer { sqlite3_finalize(statement) }
            try bind(trimmed.title, at: 1, in: statement)
            try bind(trimmed.artist, at: 2, in: statement)
            try bind(trimmed.album, at: 3, in: statement)
            try bind(trimmed.albumArtist, at: 4, in: statement)
            sqlite3_bind_int64(statement, 5, id)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DatabaseError.sqlite(errorMessage(handle))
            }

            let savedRule = try rule.map { try saveEdit($0, handle: handle) }
            try clearLocalChartCaches(handle: handle)
            try Self.execute(handle, "COMMIT")
            return ListenEditResult(listen: original.withProcessed(trimmed), rule: savedRule)
        } catch {
            try? Self.execute(handle, "ROLLBACK")
            throw error
        }
    }

    /// Removes the listen and its delivery rows, records the one-way dedup
    /// tombstone and invalidates every local chart result in one transaction.
    public func deleteListen(id: Int64, at date: Date) async throws {
        let handle = try database()
        try Self.execute(handle, "BEGIN IMMEDIATE")
        do {
            guard let listen = try listenRow(id: id, handle: handle) else {
                throw ListenMutationError.notFound
            }
            let tombstone = try prepare(
                handle,
                "INSERT OR REPLACE INTO deleted_listens (dedup_hash, deleted_at) VALUES (?, ?)",
            )
            defer { sqlite3_finalize(tombstone) }
            try bind(ListenTombstone.hash(of: listen.dedupKey), at: 1, in: tombstone)
            sqlite3_bind_double(tombstone, 2, date.timeIntervalSince1970)
            guard sqlite3_step(tombstone) == SQLITE_DONE else {
                throw DatabaseError.sqlite(errorMessage(handle))
            }

            let statement = try prepare(handle, "DELETE FROM listens WHERE id = ?")
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, id)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DatabaseError.sqlite(errorMessage(handle))
            }

            try clearLocalChartCaches(handle: handle)
            try Self.execute(handle, "COMMIT")
        } catch {
            try? Self.execute(handle, "ROLLBACK")
            throw error
        }
    }
}

// MARK: - Tombstone reads

extension SQLiteListenStore {
    /// Used by the insert transaction to refuse a play that was explicitly
    /// deleted. The hash is computed from the same durable dedup key.
    func isTombstoned(_ dedupKey: String, handle: OpaquePointer) throws -> Bool {
        let statement = try prepare(
            handle,
            "SELECT 1 FROM deleted_listens WHERE dedup_hash = ? LIMIT 1",
        )
        defer { sqlite3_finalize(statement) }
        try bind(ListenTombstone.hash(of: dedupKey), at: 1, in: statement)
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw DatabaseError.sqlite(errorMessage(handle))
        }
    }

    /// One row with the same column order as ``readListenRow``.
    private func listenRow(id: Int64, handle: OpaquePointer) throws -> Listen? {
        let statement = try prepare(
            handle,
            """
            SELECT id, raw_title, raw_artist, raw_album, raw_album_artist,
                   title, artist, album, album_artist, bundle_id,
                   duration, played_duration, started_at, captured_at, artwork_hash
            FROM listens
            WHERE id = ?
            """,
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, id)
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return readListen(statement, offset: 0)
        case SQLITE_DONE: return nil
        default: throw DatabaseError.sqlite(errorMessage(handle))
        }
    }
}

// MARK: - Test introspection

extension SQLiteListenStore {
    func tombstoneHashes() throws -> [String] {
        let handle = try database()
        let statement = try prepare(handle, "SELECT dedup_hash FROM deleted_listens")
        defer { sqlite3_finalize(statement) }
        var hashes: [String] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                hashes.append(text(statement, 0))
            case SQLITE_DONE:
                return hashes
            default:
                throw DatabaseError.sqlite(errorMessage(handle))
            }
        }
    }

    func tombstoneCount() throws -> Int {
        try Self.intValue(database(), "SELECT COUNT(*) FROM deleted_listens")
    }
}
