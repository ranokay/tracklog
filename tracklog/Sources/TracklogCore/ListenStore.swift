import Foundation

/// Durable local history. A background actor in production, a fake in tests.
public protocol ListenStore: Sendable {
    /// Stores one listen. Returns the stored record, or `nil` when the durable
    /// duplicate key already exists.
    func insert(_ listen: Listen) async throws -> Listen?
    /// Stored listens newest first, by start time and then row id.
    func recent(limit: Int) async throws -> [Listen]
}
