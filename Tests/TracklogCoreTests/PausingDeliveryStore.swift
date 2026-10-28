import Foundation
@testable import TracklogCore

/// A real store whose next `pendingDeliveries()` read captures its rows and
/// then waits, so a test can finish a newer read first and prove the older
/// snapshot cannot overwrite it.
actor PausingDeliveryStore: ListenStore, ConnectionStore, DeliveryStore {
    private let base: SQLiteListenStore
    private var pauseNextPending = false
    private var isPaused = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ base: SQLiteListenStore) {
        self.base = base
    }

    func pauseNextPendingRead() {
        pauseNextPending = true
    }

    func waitUntilPaused() async {
        while !isPaused {
            await Task.yield()
        }
    }

    func releasePendingRead() {
        isPaused = false
        continuation?.resume()
        continuation = nil
    }

    func pendingDeliveries() async throws -> [QueuedDelivery] {
        let rows = try await base.pendingDeliveries()
        if pauseNextPending {
            pauseNextPending = false
            isPaused = true
            await withCheckedContinuation { continuation = $0 }
        }
        return rows
    }

    // MARK: ListenStore

    func insert(_ listen: Listen) async throws -> Listen? {
        try await base.insert(listen)
    }

    func insert(_ listen: Listen, targets: [Int64]) async throws -> Listen? {
        try await base.insert(listen, targets: targets)
    }

    func page(limit: Int, before cursor: ListenCursor?) async throws -> [Listen] {
        try await base.page(limit: limit, before: cursor)
    }

    func count() async throws -> Int {
        try await base.count()
    }

    func count(in range: Range<Date>) async throws -> Int {
        try await base.count(in: range)
    }

    // MARK: ConnectionStore

    func connections() async throws -> [Connection] {
        try await base.connections()
    }

    func save(_ connection: Connection) async throws -> Connection {
        try await base.save(connection)
    }

    func deleteConnection(id: Int64) async throws {
        try await base.deleteConnection(id: id)
    }

    func currentConnectionID() async throws -> Int64? {
        try await base.currentConnectionID()
    }

    func setCurrentConnectionID(_ id: Int64?) async throws {
        try await base.setCurrentConnectionID(id)
    }

    // MARK: DeliveryStore

    func dueDeliveries(
        for connectionID: Int64,
        limit: Int,
        at date: Date,
    ) async throws -> [QueuedDelivery] {
        try await base.dueDeliveries(for: connectionID, limit: limit, at: date)
    }

    func deliveries(for listenID: Int64) async throws -> [Delivery] {
        try await base.deliveries(for: listenID)
    }

    func deliveries(forListenIDs listenIDs: [Int64]) async throws -> [Delivery] {
        try await base.deliveries(forListenIDs: listenIDs)
    }

    func markDelivered(_ deliveryID: Int64, at date: Date, reference: String?) async throws {
        try await base.markDelivered(deliveryID, at: date, reference: reference)
    }

    func markFailed(
        _ deliveryID: Int64,
        attempts: Int,
        at date: Date,
        nextAttemptAt: Date,
        error: String,
    ) async throws {
        try await base.markFailed(
            deliveryID,
            attempts: attempts,
            at: date,
            nextAttemptAt: nextAttemptAt,
            error: error,
        )
    }

    func abandon(
        _ deliveryID: Int64,
        attempts: Int,
        lastAttemptAt: Date?,
        reason: String,
    ) async throws {
        try await base.abandon(
            deliveryID,
            attempts: attempts,
            lastAttemptAt: lastAttemptAt,
            reason: reason,
        )
    }

    func markDue(for connectionID: Int64, at date: Date) async throws {
        try await base.markDue(for: connectionID, at: date)
    }

    func earliestNextAttempt(for connectionIDs: [Int64]) async throws -> Date? {
        try await base.earliestNextAttempt(for: connectionIDs)
    }
}
