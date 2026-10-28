import Foundation
import SQLite3

// MARK: - Writing a listen with its deliveries

extension SQLiteListenStore {
    public func insert(_ listen: Listen) async throws -> Listen? {
        try insertListen(listen, targets: [])
    }

    /// Writes one listen and its waiting delivery rows in one transaction. A
    /// duplicate key rolls back the whole write, so a reload can never create
    /// a second delivery for the same play.
    func insertListen(_ listen: Listen, targets: [Int64]) throws -> Listen? {
        let handle = try database()
        try Self.execute(handle, "BEGIN IMMEDIATE")
        do {
            guard let stored = try insertListenRow(listen, handle: handle) else {
                try Self.execute(handle, "COMMIT")
                return nil
            }
            for connectionID in Set(targets).sorted() {
                try insertDeliveryRow(
                    listenID: stored.id ?? 0,
                    connectionID: connectionID,
                    dueAt: listen.capturedAt,
                    handle: handle,
                )
            }
            try Self.execute(handle, "COMMIT")
            return stored
        } catch {
            try? Self.execute(handle, "ROLLBACK")
            throw error
        }
    }

    private func insertListenRow(_ listen: Listen, handle: OpaquePointer) throws -> Listen? {
        let statement = try prepare(
            handle,
            """
            INSERT OR IGNORE INTO listens (
                raw_title, raw_artist, raw_album, raw_album_artist,
                title, artist, album, album_artist,
                bundle_id, duration, played_duration, started_at, captured_at, dedup_key,
                artwork_hash, track_identity
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
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
        let trackIdentity = listen.raw.identity
        let artworkHash = try listen.artworkHash ?? existingArtworkHash(handle, forTrack: trackIdentity)
        if let artworkHash {
            try bind(artworkHash, at: 15, in: statement)
        } else {
            sqlite3_bind_null(statement, 15)
        }
        try bind(trackIdentity, at: 16, in: statement)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.sqlite(errorMessage(handle))
        }
        guard sqlite3_changes(handle) > 0 else { return nil }
        return listen.stored(withID: sqlite3_last_insert_rowid(handle)).withArtworkHash(artworkHash)
    }
}

// MARK: - Deliveries

public extension SQLiteListenStore {
    func insert(_ listen: Listen, targets: [Int64]) async throws -> Listen? {
        try insertListen(listen, targets: targets)
    }

    func dueDeliveries(
        for connectionID: Int64,
        limit: Int,
        at date: Date,
    ) async throws -> [QueuedDelivery] {
        guard limit > 0 else { return [] }
        let handle = try database()
        let statement = try prepare(
            handle,
            """
            SELECT \(Self.deliveryColumns),
                   l.id, l.raw_title, l.raw_artist, l.raw_album, l.raw_album_artist,
                   l.title, l.artist, l.album, l.album_artist, l.bundle_id,
                   l.duration, l.played_duration, l.started_at, l.captured_at, l.artwork_hash
            FROM deliveries d
            JOIN listens l ON l.id = d.listen_id
            WHERE d.connection_id = ?
              AND d.state IN ('waiting', 'retrying')
              AND d.next_attempt_at <= ?
            ORDER BY l.started_at ASC, l.id ASC, d.id ASC
            LIMIT ?
            """,
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, connectionID)
        sqlite3_bind_double(statement, 2, date.timeIntervalSince1970)
        sqlite3_bind_int(statement, 3, Int32(clamping: limit))

        return try readQueuedDeliveries(statement, handle: handle)
    }

    func deliveries(for listenID: Int64) async throws -> [Delivery] {
        try await deliveries(forListenIDs: [listenID])
    }

    func deliveries(forListenIDs listenIDs: [Int64]) async throws -> [Delivery] {
        guard !listenIDs.isEmpty else { return [] }
        let handle = try database()
        let placeholders = Array(repeating: "?", count: listenIDs.count).joined(separator: ", ")
        let statement = try prepare(
            handle,
            """
            SELECT \(Self.deliveryColumns)
            FROM deliveries d
            WHERE d.listen_id IN (\(placeholders))
            ORDER BY d.listen_id ASC, d.connection_id ASC, d.id ASC
            """,
        )
        defer { sqlite3_finalize(statement) }
        for (offset, listenID) in listenIDs.enumerated() {
            sqlite3_bind_int64(statement, Int32(offset + 1), listenID)
        }

        var deliveries: [Delivery] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                try deliveries.append(readDelivery(statement, offset: 0))
            case SQLITE_DONE:
                return deliveries
            default:
                throw DatabaseError.sqlite(errorMessage(handle))
            }
        }
    }

    func pendingDeliveries() async throws -> [QueuedDelivery] {
        let handle = try database()
        let statement = try prepare(
            handle,
            """
            SELECT \(Self.deliveryColumns),
                   l.id, l.raw_title, l.raw_artist, l.raw_album, l.raw_album_artist,
                   l.title, l.artist, l.album, l.album_artist, l.bundle_id,
                   l.duration, l.played_duration, l.started_at, l.captured_at, l.artwork_hash
            FROM deliveries d
            JOIN listens l ON l.id = d.listen_id
            WHERE d.state IN ('waiting', 'retrying')
            ORDER BY l.started_at ASC, l.id ASC, d.connection_id ASC, d.id ASC
            """,
        )
        defer { sqlite3_finalize(statement) }
        return try readQueuedDeliveries(statement, handle: handle)
    }

    func markDelivered(_ deliveryID: Int64, at date: Date, reference: String?) async throws {
        let handle = try database()
        let statement = try prepare(
            handle,
            """
            UPDATE deliveries
            SET state = 'delivered',
                last_attempt_at = ?,
                next_attempt_at = NULL,
                last_error = NULL,
                delivered_at = ?,
                service_reference = ?
            WHERE id = ? AND state IN ('waiting', 'retrying')
            """,
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, date.timeIntervalSince1970)
        if let reference {
            try bind(reference, at: 3, in: statement)
        } else {
            sqlite3_bind_null(statement, 3)
        }
        sqlite3_bind_int64(statement, 4, deliveryID)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.sqlite(errorMessage(handle))
        }
    }

    func markFailed(
        _ deliveryID: Int64,
        attempts: Int,
        at date: Date,
        nextAttemptAt: Date,
        error: String,
    ) async throws {
        let handle = try database()
        let statement = try prepare(
            handle,
            """
            UPDATE deliveries
            SET state = 'retrying',
                attempts = ?,
                last_attempt_at = ?,
                next_attempt_at = ?,
                last_error = ?
            WHERE id = ? AND state IN ('waiting', 'retrying')
            """,
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(clamping: attempts))
        sqlite3_bind_double(statement, 2, date.timeIntervalSince1970)
        sqlite3_bind_double(statement, 3, nextAttemptAt.timeIntervalSince1970)
        try bind(error, at: 4, in: statement)
        sqlite3_bind_int64(statement, 5, deliveryID)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.sqlite(errorMessage(handle))
        }
    }

    func abandon(
        _ deliveryID: Int64,
        attempts: Int,
        at date: Date,
        reason: String,
    ) async throws {
        let handle = try database()
        let statement = try prepare(
            handle,
            """
            UPDATE deliveries
            SET state = 'abandoned',
                attempts = ?,
                last_attempt_at = ?,
                next_attempt_at = NULL,
                last_error = ?,
                abandoned_reason = ?
            WHERE id = ?
            """,
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(clamping: attempts))
        sqlite3_bind_double(statement, 2, date.timeIntervalSince1970)
        try bind(reason, at: 3, in: statement)
        try bind(reason, at: 4, in: statement)
        sqlite3_bind_int64(statement, 5, deliveryID)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.sqlite(errorMessage(handle))
        }
    }

    func markDue(for connectionID: Int64, at date: Date) async throws {
        let handle = try database()
        let statement = try prepare(
            handle,
            """
            UPDATE deliveries
            SET next_attempt_at = ?
            WHERE connection_id = ? AND state IN ('waiting', 'retrying')
            """,
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
        sqlite3_bind_int64(statement, 2, connectionID)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.sqlite(errorMessage(handle))
        }
    }

    func earliestNextAttempt(for connectionIDs: [Int64]) async throws -> Date? {
        guard !connectionIDs.isEmpty else { return nil }
        let handle = try database()
        let placeholders = Array(repeating: "?", count: connectionIDs.count).joined(separator: ", ")
        let statement = try prepare(
            handle,
            """
            SELECT MIN(next_attempt_at)
            FROM deliveries
            WHERE state IN ('waiting', 'retrying')
              AND connection_id IN (\(placeholders))
            """,
        )
        defer { sqlite3_finalize(statement) }
        for (offset, connectionID) in connectionIDs.enumerated() {
            sqlite3_bind_int64(statement, Int32(offset + 1), connectionID)
        }
        guard sqlite3_step(statement) == SQLITE_ROW,
              sqlite3_column_type(statement, 0) != SQLITE_NULL
        else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
    }
}

// MARK: - Helpers

extension SQLiteListenStore {
    /// The number of columns in `deliveryColumns`, so a query can place the
    /// listen columns immediately after them without a second literal.
    static let deliveryColumnCount = 11
    static let deliveryColumns = """
    d.id, d.listen_id, d.connection_id, d.state, d.attempts, d.last_attempt_at,
    d.next_attempt_at, d.last_error, d.abandoned_reason, d.delivered_at, d.service_reference
    """

    private func readQueuedDeliveries(
        _ statement: OpaquePointer,
        handle: OpaquePointer,
    ) throws -> [QueuedDelivery] {
        var queued: [QueuedDelivery] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                try queued.append(
                    QueuedDelivery(
                        delivery: readDelivery(statement, offset: 0),
                        listen: readListen(statement, offset: Int32(Self.deliveryColumnCount)),
                    ),
                )
            case SQLITE_DONE:
                return queued
            default:
                throw DatabaseError.sqlite(errorMessage(handle))
            }
        }
    }

    func insertDeliveryRow(
        listenID: Int64,
        connectionID: Int64,
        dueAt: Date,
        handle: OpaquePointer,
    ) throws {
        // A connection unlinked between capture and this write is no longer a
        // target. Skipping it keeps the listen, which is the authoritative
        // record, instead of failing the whole transaction.
        let statement = try prepare(
            handle,
            """
            INSERT INTO deliveries (listen_id, connection_id, state, attempts, next_attempt_at)
            SELECT ?, id, 'waiting', 0, ?
            FROM connections
            WHERE id = ?
            """,
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, listenID)
        sqlite3_bind_double(statement, 2, dueAt.timeIntervalSince1970)
        sqlite3_bind_int64(statement, 3, connectionID)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.sqlite(errorMessage(handle))
        }
    }

    private func readDelivery(_ statement: OpaquePointer, offset: Int32) throws -> Delivery {
        guard let state = DeliveryState(rawValue: text(statement, offset + 3)) else {
            throw DatabaseError.sqlite("a stored delivery has an unknown state")
        }
        return Delivery(
            id: sqlite3_column_int64(statement, offset),
            listenID: sqlite3_column_int64(statement, offset + 1),
            connectionID: sqlite3_column_int64(statement, offset + 2),
            state: state,
            attempts: Int(sqlite3_column_int64(statement, offset + 4)),
            lastAttemptAt: optionalDate(statement, offset + 5),
            nextAttemptAt: optionalDate(statement, offset + 6),
            lastError: optionalText(statement, offset + 7),
            abandonedReason: optionalText(statement, offset + 8),
            deliveredAt: optionalDate(statement, offset + 9),
            serviceReference: optionalText(statement, offset + 10),
        )
    }

    private func optionalText(_ statement: OpaquePointer, _ index: Int32) -> String? {
        sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : text(statement, index)
    }

    private func optionalDate(_ statement: OpaquePointer, _ index: Int32) -> Date? {
        sqlite3_column_type(statement, index) == SQLITE_NULL
            ? nil
            : Date(timeIntervalSince1970: sqlite3_column_double(statement, index))
    }
}
