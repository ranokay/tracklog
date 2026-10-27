import Foundation

/// The last row of one history page, used as the cursor for the next.
public struct ListenCursor: Equatable, Sendable {
    public let startedAt: Date
    public let id: Int64

    public init(startedAt: Date, id: Int64) {
        self.startedAt = startedAt
        self.id = id
    }

    public init?(_ listen: Listen) {
        guard let id = listen.id else { return nil }
        self.init(startedAt: listen.startedAt, id: id)
    }
}

/// Durable local history. A background actor in production, a fake in tests.
public protocol ListenStore: Sendable {
    /// Stores one listen. Returns the stored record, or `nil` when the durable
    /// duplicate key already exists.
    func insert(_ listen: Listen) async throws -> Listen?
    /// One page of stored listens, newest first by start time and then row id.
    /// A cursor returns the rows strictly older than that row.
    func page(limit: Int, before cursor: ListenCursor?) async throws -> [Listen]
    /// Total stored listens, including rows outside the loaded page.
    func count() async throws -> Int
    /// How many stored listens started inside `range`.
    func count(in range: Range<Date>) async throws -> Int
}

public extension ListenStore {
    /// The newest listens, with no cursor.
    func recent(limit: Int) async throws -> [Listen] {
        try await page(limit: limit, before: nil)
    }

    /// Fakes can answer a day count from their pages; the SQLite store counts
    /// in SQL instead.
    func count(in range: Range<Date>) async throws -> Int {
        try await page(limit: Int.max, before: nil)
            .filter { range.contains($0.startedAt) }
            .count
    }
}
