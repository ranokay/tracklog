import Foundation
import SQLite3

// MARK: - Feedback

public extension SQLiteListenStore {
    func feedback(for identities: [String]) async throws -> [String: TrackFeedback] {
        let identities = Array(Set(identities.filter { !$0.isEmpty }))
        guard !identities.isEmpty else { return [:] }
        let handle = try database()
        let placeholders = Array(repeating: "?", count: identities.count).joined(separator: ", ")
        let statement = try prepare(
            handle,
            """
            SELECT track_identity, score, updated_at
            FROM feedback
            WHERE track_identity IN (\(placeholders))
            """,
        )
        defer { sqlite3_finalize(statement) }
        for (index, identity) in identities.enumerated() {
            try bind(identity, at: Int32(index + 1), in: statement)
        }

        var loaded: [String: TrackFeedback] = [:]
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                let identity = text(statement, 0)
                guard let score = FeedbackScore(rawValue: text(statement, 1)) else {
                    continue
                }
                loaded[identity] = TrackFeedback(
                    identity: identity,
                    score: score,
                    updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                )
            case SQLITE_DONE:
                return loaded
            default:
                throw DatabaseError.sqlite(errorMessage(handle))
            }
        }
    }

    func setFeedback(
        _ score: FeedbackScore?,
        for identity: String,
        at date: Date,
    ) async throws {
        let handle = try database()
        guard let score else {
            let statement = try prepare(handle, "DELETE FROM feedback WHERE track_identity = ?")
            defer { sqlite3_finalize(statement) }
            try bind(identity, at: 1, in: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DatabaseError.sqlite(errorMessage(handle))
            }
            return
        }

        let statement = try prepare(
            handle,
            """
            INSERT INTO feedback (track_identity, score, updated_at)
            VALUES (?, ?, ?)
            ON CONFLICT(track_identity) DO UPDATE SET
                score = excluded.score,
                updated_at = excluded.updated_at
            """,
        )
        defer { sqlite3_finalize(statement) }
        try bind(identity, at: 1, in: statement)
        try bind(score.rawValue, at: 2, in: statement)
        sqlite3_bind_double(statement, 3, date.timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.sqlite(errorMessage(handle))
        }
    }
}
