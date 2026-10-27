import Foundation
import SQLite3

// MARK: - App allowlist

public extension SQLiteListenStore {
    func apps() async throws -> [SeenApp] {
        let handle = try database()
        let statement = try prepare(
            handle,
            """
            SELECT bundle_id, allowed
            FROM apps
            ORDER BY id ASC
            """,
        )
        defer { sqlite3_finalize(statement) }

        var apps: [SeenApp] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                apps.append(readApp(statement))
            case SQLITE_DONE:
                return apps
            default:
                throw DatabaseError.sqlite(errorMessage(handle))
            }
        }
    }

    func isAllowed(_ bundleID: String) async throws -> Bool {
        let normalized = Self.normalizedBundleID(bundleID)
        guard !normalized.isEmpty else { return false }

        let handle = try database()
        let statement = try prepare(handle, "SELECT allowed FROM apps WHERE bundle_id = ?")
        defer { sqlite3_finalize(statement) }
        try bind(normalized, at: 1, in: statement)

        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return sqlite3_column_int(statement, 0) == 1
        case SQLITE_DONE:
            return false
        default:
            throw DatabaseError.sqlite(errorMessage(handle))
        }
    }

    @discardableResult
    func recordSeen(_ bundleID: String) async throws -> SeenApp? {
        let normalized = Self.normalizedBundleID(bundleID)
        guard !normalized.isEmpty else { return nil }

        let handle = try database()
        let statement = try prepare(handle, "INSERT OR IGNORE INTO apps (bundle_id, allowed) VALUES (?, 0)")
        defer { sqlite3_finalize(statement) }
        try bind(normalized, at: 1, in: statement)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.sqlite(errorMessage(handle))
        }
        return try app(bundleID: normalized, handle: handle)
    }

    func setAllowed(_ bundleID: String, allowed: Bool) async throws {
        let normalized = Self.normalizedBundleID(bundleID)
        guard !normalized.isEmpty else { return }

        let handle = try database()
        let statement = try prepare(handle, "UPDATE apps SET allowed = ? WHERE bundle_id = ?")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, allowed ? 1 : 0)
        try bind(normalized, at: 2, in: statement)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.sqlite(errorMessage(handle))
        }
    }

    private func app(bundleID: String, handle: OpaquePointer) throws -> SeenApp? {
        let statement = try prepare(
            handle,
            "SELECT bundle_id, allowed FROM apps WHERE bundle_id = ?",
        )
        defer { sqlite3_finalize(statement) }
        try bind(bundleID, at: 1, in: statement)

        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return readApp(statement)
        case SQLITE_DONE:
            return nil
        default:
            throw DatabaseError.sqlite(errorMessage(handle))
        }
    }

    private func readApp(_ statement: OpaquePointer) -> SeenApp {
        SeenApp(
            bundleID: text(statement, 0),
            isAllowed: sqlite3_column_int(statement, 1) == 1,
        )
    }

    private static func normalizedBundleID(_ bundleID: String) -> String {
        bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Seeding

extension SQLiteListenStore {
    /// The first-run defaults, written once by migration 2. `INSERT OR IGNORE`
    /// keeps a row that already exists rather than restoring a user decision.
    static func seedDefaultApps(_ handle: OpaquePointer) throws {
        for bundleID in SeededPlayers.bundleIDs {
            try execute(
                handle,
                "INSERT OR IGNORE INTO apps (bundle_id, allowed) VALUES ('\(bundleID)', 1)",
            )
        }
    }
}
