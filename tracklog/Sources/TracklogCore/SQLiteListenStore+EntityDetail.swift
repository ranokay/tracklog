import Foundation
import SQLite3

// MARK: - Local detail

extension SQLiteListenStore: EntityDetailStore {
    public func entityLocalDetail(
        kind: EntityKind,
        key: String,
        topTrackLimit: Int,
    ) async throws -> EntityLocalDetail {
        try await chartReader.entityLocalDetail(
            kind: kind,
            key: key,
            topTrackLimit: topTrackLimit,
        )
    }

    // MARK: - Image overrides

    public func imageOverrides() async throws -> [ImageOverride] {
        let handle = try database()
        let statement = try prepare(
            handle,
            """
            SELECT entity_kind, entity_key, display_title, display_subtitle,
                   artwork_hash, updated_at
            FROM image_overrides
            ORDER BY updated_at DESC, entity_kind ASC, entity_key ASC
            """,
        )
        defer { sqlite3_finalize(statement) }
        var values: [ImageOverride] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let value = imageOverrideRow(statement) else { continue }
            values.append(value)
        }
        return values
    }

    public func imageOverride(kind: EntityKind, key: String) async throws -> ImageOverride? {
        try readImageOverride(kind: kind, key: key, handle: database())
    }

    public func saveImageOverride(
        _ override: ImageOverride,
        artwork: StoredArtwork,
    ) async throws {
        let handle = try database()
        try Self.execute(handle, "BEGIN IMMEDIATE")
        do {
            let oldHash = try imageOverrideHash(
                kind: override.kind,
                key: override.key,
                handle: handle,
            )
            try insertArtwork(artwork, handle: handle)
            let statement = try prepare(
                handle,
                """
                INSERT INTO image_overrides (
                    entity_kind, entity_key, display_title, display_subtitle,
                    artwork_hash, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(entity_kind, entity_key) DO UPDATE SET
                    display_title = excluded.display_title,
                    display_subtitle = excluded.display_subtitle,
                    artwork_hash = excluded.artwork_hash,
                    updated_at = excluded.updated_at
                """,
            )
            defer { sqlite3_finalize(statement) }
            try bind(override.kind.rawValue, at: 1, in: statement)
            try bind(override.key, at: 2, in: statement)
            try bind(override.title, at: 3, in: statement)
            try bind(override.subtitle, at: 4, in: statement)
            try bind(override.artworkHash, at: 5, in: statement)
            sqlite3_bind_double(statement, 6, override.updatedAt.timeIntervalSince1970)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DatabaseError.sqlite(errorMessage(handle))
            }
            try deleteArtworkIfUnreferenced(oldHash, handle: handle)
            try Self.execute(handle, "COMMIT")
        } catch {
            try? Self.execute(handle, "ROLLBACK")
            throw error
        }
    }

    public func removeImageOverride(kind: EntityKind, key: String) async throws {
        let handle = try database()
        try Self.execute(handle, "BEGIN IMMEDIATE")
        do {
            let oldHash = try imageOverrideHash(kind: kind, key: key, handle: handle)
            let statement = try prepare(
                handle,
                "DELETE FROM image_overrides WHERE entity_kind = ? AND entity_key = ?",
            )
            defer { sqlite3_finalize(statement) }
            try bind(kind.rawValue, at: 1, in: statement)
            try bind(key, at: 2, in: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DatabaseError.sqlite(errorMessage(handle))
            }
            try deleteArtworkIfUnreferenced(oldHash, handle: handle)
            try Self.execute(handle, "COMMIT")
        } catch {
            try? Self.execute(handle, "ROLLBACK")
            throw error
        }
    }

    // MARK: - Artist image cache

    public func artistImageCache(forArtist key: String) async throws -> ArtistImageCacheEntry? {
        let handle = try database()
        let statement = try prepare(
            handle,
            """
            SELECT artist_key, artwork_hash, outcome, checked_at
            FROM artist_image_cache WHERE artist_key = ?
            """,
        )
        defer { sqlite3_finalize(statement) }
        try bind(key, at: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return artistImageCacheRow(statement)
    }

    public func saveArtistImageCache(
        _ entry: ArtistImageCacheEntry,
        artwork: StoredArtwork?,
    ) async throws {
        let handle = try database()
        try Self.execute(handle, "BEGIN IMMEDIATE")
        do {
            try pruneExpiredArtistImageCache(now: entry.checkedAt, handle: handle)
            let oldHash = try artistImageCacheHash(artistKey: entry.artistKey, handle: handle)
            if let artwork {
                try insertArtwork(artwork, handle: handle)
            }
            let statement = try prepare(
                handle,
                """
                INSERT INTO artist_image_cache (artist_key, artwork_hash, outcome, checked_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(artist_key) DO UPDATE SET
                    artwork_hash = excluded.artwork_hash,
                    outcome = excluded.outcome,
                    checked_at = excluded.checked_at
                """,
            )
            defer { sqlite3_finalize(statement) }
            try bind(entry.artistKey, at: 1, in: statement)
            if let hash = entry.artworkHash {
                try bind(hash, at: 2, in: statement)
            } else {
                sqlite3_bind_null(statement, 2)
            }
            try bind(entry.outcome.rawValue, at: 3, in: statement)
            sqlite3_bind_double(statement, 4, entry.checkedAt.timeIntervalSince1970)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DatabaseError.sqlite(errorMessage(handle))
            }
            try deleteArtworkIfUnreferenced(oldHash, handle: handle)
            try Self.execute(handle, "COMMIT")
        } catch {
            try? Self.execute(handle, "ROLLBACK")
            throw error
        }
    }

    public func pruneExpiredArtistImageCache(now: Date) async throws {
        let handle = try database()
        try Self.execute(handle, "BEGIN IMMEDIATE")
        do {
            try pruneExpiredArtistImageCache(now: now, handle: handle)
            try Self.execute(handle, "COMMIT")
        } catch {
            try? Self.execute(handle, "ROLLBACK")
            throw error
        }
    }

    // MARK: - Reference-aware blob lifetime

    /// Deletes one content-addressed artwork row only when no listen, track
    /// mapping, override or approximate-image cache entry still names it. This
    /// is what makes Remove actually remove the user's copy without breaking a
    /// captured cover that happens to share the bytes.
    func deleteArtworkIfUnreferenced(_ hash: String?, handle: OpaquePointer) throws {
        guard let hash, !hash.isEmpty else { return }
        let reference = try prepare(
            handle,
            """
            SELECT 1 FROM listens WHERE artwork_hash = ?
            UNION ALL SELECT 1 FROM track_artwork WHERE artwork_hash = ?
            UNION ALL SELECT 1 FROM image_overrides WHERE artwork_hash = ?
            UNION ALL SELECT 1 FROM artist_image_cache WHERE artwork_hash = ?
            LIMIT 1
            """,
        )
        defer { sqlite3_finalize(reference) }
        for index in 1 ... 4 {
            try bind(hash, at: Int32(index), in: reference)
        }
        if sqlite3_step(reference) == SQLITE_ROW {
            return
        }
        let delete = try prepare(handle, "DELETE FROM artwork WHERE hash = ?")
        defer { sqlite3_finalize(delete) }
        try bind(hash, at: 1, in: delete)
        guard sqlite3_step(delete) == SQLITE_DONE else {
            throw DatabaseError.sqlite(errorMessage(handle))
        }
    }

    // MARK: - Rows

    private func readImageOverride(
        kind: EntityKind,
        key: String,
        handle: OpaquePointer,
    ) throws -> ImageOverride? {
        let statement = try prepare(
            handle,
            """
            SELECT entity_kind, entity_key, display_title, display_subtitle,
                   artwork_hash, updated_at
            FROM image_overrides
            WHERE entity_kind = ? AND entity_key = ?
            """,
        )
        defer { sqlite3_finalize(statement) }
        try bind(kind.rawValue, at: 1, in: statement)
        try bind(key, at: 2, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return imageOverrideRow(statement)
    }

    private func imageOverrideRow(_ statement: OpaquePointer) -> ImageOverride? {
        guard let kind = EntityKind(rawValue: text(statement, 0)) else { return nil }
        return ImageOverride(
            kind: kind,
            key: text(statement, 1),
            title: text(statement, 2),
            subtitle: text(statement, 3),
            artworkHash: text(statement, 4),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
        )
    }

    private func imageOverrideHash(
        kind: EntityKind,
        key: String,
        handle: OpaquePointer,
    ) throws -> String? {
        let statement = try prepare(
            handle,
            "SELECT artwork_hash FROM image_overrides WHERE entity_kind = ? AND entity_key = ?",
        )
        defer { sqlite3_finalize(statement) }
        try bind(kind.rawValue, at: 1, in: statement)
        try bind(key, at: 2, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return text(statement, 0)
    }

    private func artistImageCacheRow(_ statement: OpaquePointer) -> ArtistImageCacheEntry? {
        guard let outcome = ArtistImageCacheOutcome(rawValue: text(statement, 2)) else {
            return nil
        }
        let hash = sqlite3_column_type(statement, 1) == SQLITE_NULL
            ? nil
            : text(statement, 1)
        return ArtistImageCacheEntry(
            artistKey: text(statement, 0),
            artworkHash: hash,
            outcome: outcome,
            checkedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
        )
    }

    private func artistImageCacheHash(
        artistKey: String,
        handle: OpaquePointer,
    ) throws -> String? {
        let statement = try prepare(
            handle,
            "SELECT artwork_hash FROM artist_image_cache WHERE artist_key = ?",
        )
        defer { sqlite3_finalize(statement) }
        try bind(artistKey, at: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW,
              sqlite3_column_type(statement, 0) != SQLITE_NULL
        else { return nil }
        return text(statement, 0)
    }

    /// Expired rows are removed, and each old hash is garbage-collected once no
    /// other row names it. Runs inside the caller's transaction.
    private func pruneExpiredArtistImageCache(now: Date, handle: OpaquePointer) throws {
        let select = try prepare(
            handle,
            """
            SELECT artist_key, artwork_hash, outcome, checked_at
            FROM artist_image_cache
            """,
        )
        var expired: [(key: String, hash: String?)] = []
        while true {
            switch sqlite3_step(select) {
            case SQLITE_ROW:
                guard let entry = artistImageCacheRow(select) else { continue }
                if !entry.isFresh(now: now) {
                    expired.append((entry.artistKey, entry.artworkHash))
                }
            case SQLITE_DONE:
                sqlite3_finalize(select)
                for row in expired {
                    let delete = try prepare(
                        handle,
                        "DELETE FROM artist_image_cache WHERE artist_key = ?",
                    )
                    try bind(row.key, at: 1, in: delete)
                    guard sqlite3_step(delete) == SQLITE_DONE else {
                        sqlite3_finalize(delete)
                        throw DatabaseError.sqlite(errorMessage(handle))
                    }
                    sqlite3_finalize(delete)
                    try deleteArtworkIfUnreferenced(row.hash, handle: handle)
                }
                return
            default:
                sqlite3_finalize(select)
                throw DatabaseError.sqlite(errorMessage(handle))
            }
        }
    }
}

// MARK: - Test introspection

extension SQLiteListenStore {
    func imageOverrideCount() throws -> Int {
        try Self.intValue(database(), "SELECT COUNT(*) FROM image_overrides")
    }

    func artistImageCacheCount() throws -> Int {
        try Self.intValue(database(), "SELECT COUNT(*) FROM artist_image_cache")
    }

    /// Test-only: replace one blob's bytes to prove the neutral-sleeve fallback
    /// for an override that is present but cannot be decoded.
    func replaceArtworkDataForTest(hash: String, data: Data) throws {
        let handle = try database()
        let statement = try prepare(handle, "UPDATE artwork SET data = ? WHERE hash = ?")
        defer { sqlite3_finalize(statement) }
        data.withUnsafeBytes { bytes in
            _ = sqlite3_bind_blob(statement, 1, bytes.baseAddress, Int32(bytes.count), Self.transient)
        }
        try bind(hash, at: 2, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.sqlite(errorMessage(handle))
        }
    }

    /// Test-only: remove one blob row to prove the neutral-sleeve fallback for
    /// an override whose stored copy vanished.
    func deleteArtworkRowForTest(hash: String) throws {
        let handle = try database()
        let statement = try prepare(handle, "DELETE FROM artwork WHERE hash = ?")
        defer { sqlite3_finalize(statement) }
        try bind(hash, at: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.sqlite(errorMessage(handle))
        }
    }
}
