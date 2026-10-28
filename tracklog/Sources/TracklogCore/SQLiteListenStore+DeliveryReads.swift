import Foundation
import SQLite3

public extension SQLiteListenStore {
    func deliveries(for listenID: Int64) async throws -> [Delivery] {
        try await deliveries(forListenIDs: [listenID])
    }

    func deliveries(forListenIDs listenIDs: [Int64]) async throws -> [Delivery] {
        guard !listenIDs.isEmpty else { return [] }
        let handle = try database()
        // A long History session can load more IDs than one IN list can bind.
        // Read in batches at SQLite's own variable limit, then restore the
        // query's global order.
        let variableLimit = max(1, Int(sqlite3_limit(handle, SQLITE_LIMIT_VARIABLE_NUMBER, -1)))
        var deliveries: [Delivery] = []
        for batch in Self.listenIDBatches(listenIDs, limit: variableLimit) {
            let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ", ")
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
            for (offset, listenID) in batch.enumerated() {
                sqlite3_bind_int64(statement, Int32(offset + 1), listenID)
            }

            rowLoop: while true {
                switch sqlite3_step(statement) {
                case SQLITE_ROW:
                    try deliveries.append(readDelivery(statement, offset: 0))
                case SQLITE_DONE:
                    break rowLoop
                default:
                    throw DatabaseError.sqlite(errorMessage(handle))
                }
            }
        }
        return deliveries.sorted { left, right in
            if left.listenID != right.listenID {
                return left.listenID < right.listenID
            }
            if left.connectionID != right.connectionID {
                return left.connectionID < right.connectionID
            }
            return left.id < right.id
        }
    }
}

extension SQLiteListenStore {
    /// Splits one long History page into bindable batches. A limit below one
    /// is treated as one variable, so an unexpected `sqlite3_limit` reading
    /// cannot produce an empty placeholder list.
    static func listenIDBatches(_ listenIDs: [Int64], limit: Int) -> [[Int64]] {
        guard !listenIDs.isEmpty else { return [] }
        let limit = max(1, limit)
        return stride(from: 0, to: listenIDs.count, by: limit).map {
            Array(listenIDs[$0 ..< min($0 + limit, listenIDs.count)])
        }
    }
}
