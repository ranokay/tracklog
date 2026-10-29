import Foundation
import SQLite3

// MARK: - Connections

public extension SQLiteListenStore {
    func connections() async throws -> [Connection] {
        let handle = try database()
        let statement = try prepare(
            handle,
            """
            SELECT \(Self.connectionColumns)
            FROM connections
            ORDER BY id ASC
            """,
        )
        defer { sqlite3_finalize(statement) }

        var connections: [Connection] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                try connections.append(readConnection(statement))
            case SQLITE_DONE:
                return connections
            default:
                throw DatabaseError.sqlite(errorMessage(handle))
            }
        }
    }

    func save(_ connection: Connection) async throws -> Connection {
        let handle = try database()
        if let id = connection.id {
            // The update and its readback are one unit: a thrown error must
            // leave the stored row exactly as it was.
            try Self.execute(handle, "BEGIN IMMEDIATE")
            do {
                guard try readConnection(id: id, handle: handle) != nil else {
                    throw ConnectionError.unknownConnection(id: id)
                }
                try updateConnectionRow(connection, id: id, handle: handle)
                let stored = try readConnection(id: id, handle: handle) ?? connection
                try Self.execute(handle, "COMMIT")
                return stored
            } catch {
                try? Self.execute(handle, "ROLLBACK")
                throw error
            }
        }

        let statement = try prepare(
            handle,
            """
            INSERT INTO connections (
                kind, endpoint, identity, display_name, enabled, auth_state,
                created_at, last_used_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
        )
        defer { sqlite3_finalize(statement) }
        try bind(connection.kind.rawValue, at: 1, in: statement)
        try bind(connection.endpoint.description, at: 2, in: statement)
        try bind(connection.identity, at: 3, in: statement)
        try bind(connection.displayName, at: 4, in: statement)
        sqlite3_bind_int(statement, 5, connection.isEnabled ? 1 : 0)
        try bind(connection.authState.rawValue, at: 6, in: statement)
        sqlite3_bind_double(statement, 7, connection.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 8, connection.lastUsedAt.timeIntervalSince1970)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            if sqlite3_errcode(handle) == SQLITE_CONSTRAINT {
                throw ConnectionError.duplicateEndpoint(
                    kind: connection.kind,
                    endpoint: connection.endpoint,
                )
            }
            throw DatabaseError.sqlite(errorMessage(handle))
        }
        return connection.stored(withID: sqlite3_last_insert_rowid(handle))
    }

    func replaceConnection(_ connection: Connection, reason: String) async throws -> ReplacedConnection {
        guard let id = connection.id else { throw ConnectionError.unknownConnection(id: -1) }
        let handle = try database()
        try Self.execute(handle, "BEGIN IMMEDIATE")
        do {
            guard try readConnection(id: id, handle: handle) != nil else {
                throw ConnectionError.unknownConnection(id: id)
            }
            try updateConnectionRow(connection, id: id, handle: handle)
            let abandoned = try abandonPending(forConnection: id, reason: reason, handle: handle)
            let stored = try readConnection(id: id, handle: handle) ?? connection
            try Self.execute(handle, "COMMIT")
            return ReplacedConnection(connection: stored, abandonedDeliveries: abandoned)
        } catch {
            try? Self.execute(handle, "ROLLBACK")
            throw error
        }
    }

    func deleteConnection(id: Int64) async throws {
        let handle = try database()
        try Self.execute(handle, "BEGIN IMMEDIATE")
        do {
            try deleteConnectionRow(id: id, handle: handle)
            try Self.execute(handle, "COMMIT")
        } catch {
            try? Self.execute(handle, "ROLLBACK")
            throw error
        }
    }

    func unlinkConnection(id: Int64, reason: String) async throws -> Int {
        let handle = try database()
        try Self.execute(handle, "BEGIN IMMEDIATE")
        do {
            let abandoned = try abandonPending(forConnection: id, reason: reason, handle: handle)
            try deleteConnectionRow(id: id, handle: handle)
            try Self.execute(handle, "COMMIT")
            return abandoned
        } catch {
            try? Self.execute(handle, "ROLLBACK")
            throw error
        }
    }

    func currentConnectionID() async throws -> Int64? {
        let handle = try database()
        let statement = try prepare(
            handle,
            "SELECT value FROM connection_preferences WHERE key = ?",
        )
        defer { sqlite3_finalize(statement) }
        try bind(Self.currentConnectionKey, at: 1, in: statement)

        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return Int64(text(statement, 0))
        case SQLITE_DONE:
            return nil
        default:
            throw DatabaseError.sqlite(errorMessage(handle))
        }
    }

    func setCurrentConnectionID(_ id: Int64?) async throws {
        let handle = try database()
        if let id {
            guard try readConnection(id: id, handle: handle) != nil else {
                throw ConnectionError.unknownConnection(id: id)
            }
            let statement = try prepare(
                handle,
                "INSERT OR REPLACE INTO connection_preferences (key, value) VALUES (?, ?)",
            )
            defer { sqlite3_finalize(statement) }
            try bind(Self.currentConnectionKey, at: 1, in: statement)
            try bind(String(id), at: 2, in: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DatabaseError.sqlite(errorMessage(handle))
            }
        } else {
            let statement = try prepare(handle, "DELETE FROM connection_preferences WHERE key = ?")
            defer { sqlite3_finalize(statement) }
            try bind(Self.currentConnectionKey, at: 1, in: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DatabaseError.sqlite(errorMessage(handle))
            }
        }
    }
}

// MARK: - Helpers

private extension SQLiteListenStore {
    static let currentConnectionKey = "current_connection_id"
    static let connectionColumns = "id, kind, endpoint, identity, display_name, enabled, auth_state, created_at, last_used_at"

    func readConnection(id: Int64, handle: OpaquePointer) throws -> Connection? {
        let statement = try prepare(
            handle,
            """
            SELECT \(Self.connectionColumns)
            FROM connections
            WHERE id = ?
            """,
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, id)

        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return try readConnection(statement)
        case SQLITE_DONE:
            return nil
        default:
            throw DatabaseError.sqlite(errorMessage(handle))
        }
    }

    func readConnection(_ statement: OpaquePointer) throws -> Connection {
        guard let kind = ServiceKind(rawValue: text(statement, 1)) else {
            throw DatabaseError.sqlite("a stored connection names an unknown service")
        }
        guard let endpoint = ServiceEndpoint(normalizing: text(statement, 2)) else {
            throw DatabaseError.sqlite("a stored connection has an invalid endpoint")
        }
        guard let authState = ConnectionAuthState(rawValue: text(statement, 6)) else {
            throw DatabaseError.sqlite("a stored connection has an unknown auth state")
        }
        return Connection(
            id: sqlite3_column_int64(statement, 0),
            kind: kind,
            endpoint: endpoint,
            identity: text(statement, 3),
            displayName: text(statement, 4),
            isEnabled: sqlite3_column_int(statement, 5) == 1,
            authState: authState,
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7)),
            lastUsedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 8)),
        )
    }

    /// Writes the mutable connection fields. The caller owns the transaction.
    func updateConnectionRow(_ connection: Connection, id: Int64, handle: OpaquePointer) throws {
        let statement = try prepare(
            handle,
            """
            UPDATE connections
            SET identity = ?, display_name = ?, enabled = ?, auth_state = ?, last_used_at = ?
            WHERE id = ?
            """,
        )
        defer { sqlite3_finalize(statement) }
        try bind(connection.identity, at: 1, in: statement)
        try bind(connection.displayName, at: 2, in: statement)
        sqlite3_bind_int(statement, 3, connection.isEnabled ? 1 : 0)
        try bind(connection.authState.rawValue, at: 4, in: statement)
        sqlite3_bind_double(statement, 5, connection.lastUsedAt.timeIntervalSince1970)
        sqlite3_bind_int64(statement, 6, id)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.sqlite(errorMessage(handle))
        }
    }

    /// Deletes one connection row and clears the cursor when it pointed at it.
    /// The caller owns the transaction, so unlink can abandon its deliveries in
    /// the same commit.
    func deleteConnectionRow(id: Int64, handle: OpaquePointer) throws {
        let statement = try prepare(handle, "DELETE FROM connections WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, id)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.sqlite(errorMessage(handle))
        }
        try clearCurrentConnection(id: id, handle: handle)
    }

    /// Deletes the cursor only when it still points at the deleted connection,
    /// so deleting an unselected connection leaves the choice alone.
    func clearCurrentConnection(id: Int64, handle: OpaquePointer) throws {
        let statement = try prepare(
            handle,
            "DELETE FROM connection_preferences WHERE key = ? AND value = ?",
        )
        defer { sqlite3_finalize(statement) }
        try bind(Self.currentConnectionKey, at: 1, in: statement)
        try bind(String(id), at: 2, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.sqlite(errorMessage(handle))
        }
    }
}
