import Foundation
import SQLite3

extension SQLiteListenStore: ArtworkStore {
    public func artwork(for hash: String) async throws -> Data? {
        let handle = try database()
        let statement = try prepare(handle, "SELECT data FROM artwork WHERE hash = ?")
        defer { sqlite3_finalize(statement) }
        try bind(hash, at: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        guard let bytes = sqlite3_column_blob(statement, 0) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
    }

    public func artworkHash(forTrack identity: String) async throws -> String? {
        try existingArtworkHash(database(), forTrack: identity)
    }

    public func attachArtwork(_ artwork: StoredArtwork, toTrack identity: String) async throws {
        let handle = try database()
        try Self.execute(handle, "BEGIN IMMEDIATE")
        do {
            try insertArtwork(artwork, handle: handle)
            try insertTrackArtwork(artwork.hash, forTrack: identity, handle: handle)
            try Self.execute(handle, "COMMIT")
        } catch {
            try? Self.execute(handle, "ROLLBACK")
            throw error
        }
    }

    // MARK: - SQL

    func existingArtworkHash(_ handle: OpaquePointer, forTrack identity: String) throws -> String? {
        let statement = try prepare(handle, "SELECT artwork_hash FROM track_artwork WHERE track_identity = ?")
        defer { sqlite3_finalize(statement) }
        try bind(identity, at: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return text(statement, 0)
    }

    private func insertArtwork(_ artwork: StoredArtwork, handle: OpaquePointer) throws {
        let statement = try prepare(
            handle,
            """
            INSERT OR IGNORE INTO artwork (hash, data, pixel_width, pixel_height, stored_at)
            VALUES (?, ?, ?, ?, ?)
            """,
        )
        defer { sqlite3_finalize(statement) }
        try bind(artwork.hash, at: 1, in: statement)
        if artwork.data.isEmpty {
            sqlite3_bind_zeroblob(statement, 2, 0)
        } else {
            let result = artwork.data.withUnsafeBytes { bytes in
                sqlite3_bind_blob(statement, 2, bytes.baseAddress, Int32(bytes.count), Self.transient)
            }
            guard result == SQLITE_OK else {
                throw DatabaseError.sqlite(errorMessage(handle))
            }
        }
        sqlite3_bind_int(statement, 3, Int32(clamping: artwork.pixelWidth))
        sqlite3_bind_int(statement, 4, Int32(clamping: artwork.pixelHeight))
        sqlite3_bind_double(statement, 5, Date().timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.sqlite(errorMessage(handle))
        }
    }

    private func insertTrackArtwork(
        _ hash: String,
        forTrack identity: String,
        handle: OpaquePointer,
    ) throws {
        let statement = try prepare(
            handle,
            """
            INSERT INTO track_artwork (track_identity, artwork_hash, updated_at)
            VALUES (?, ?, ?)
            ON CONFLICT(track_identity) DO UPDATE SET
                artwork_hash = excluded.artwork_hash,
                updated_at = excluded.updated_at
            """,
        )
        defer { sqlite3_finalize(statement) }
        try bind(identity, at: 1, in: statement)
        try bind(hash, at: 2, in: statement)
        sqlite3_bind_double(statement, 3, Date().timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.sqlite(errorMessage(handle))
        }

        // Every listen already recorded for this track shares the cover. A
        // later cover replaces the mapping, and only future listens see it.
        let update = try prepare(
            handle,
            "UPDATE listens SET artwork_hash = ? WHERE track_identity = ? AND artwork_hash IS NULL",
        )
        defer { sqlite3_finalize(update) }
        try bind(hash, at: 1, in: update)
        try bind(identity, at: 2, in: update)
        guard sqlite3_step(update) == SQLITE_DONE else {
            throw DatabaseError.sqlite(errorMessage(handle))
        }
    }
}

// MARK: - Test introspection

extension SQLiteListenStore {
    func artworkCount() throws -> Int {
        try Self.intValue(database(), "SELECT COUNT(*) FROM artwork")
    }
}
