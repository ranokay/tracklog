import Foundation
@testable import TracklogCore

/// Holds a batch inside `submit` until the test releases it, and records how
/// many batches were ever inside at once.
actor DeliveryGate {
    private var active = 0
    private(set) var peak = 0
    private var held: [CheckedContinuation<Void, Never>] = []
    private var isHolding = true

    func enter() async {
        active += 1
        peak = max(peak, active)
        guard isHolding else { return }
        await withCheckedContinuation { held.append($0) }
    }

    func leave() {
        active -= 1
    }

    func waitUntilEntered() async {
        while active == 0 {
            await Task.yield()
        }
    }

    func release() {
        isHolding = false
        let waiting = held
        held.removeAll()
        for continuation in waiting {
            continuation.resume()
        }
    }
}

/// A real store whose combined listen-and-delivery write fails, to prove that
/// a persist failure never reaches the network.
actor FailingDeliveryStore: ListenStore, ConnectionStore, DeliveryStore {
    private let base: SQLiteListenStore
    private let failInsert: Bool
    private var deliveredWritesToFail: Int

    init(
        _ base: SQLiteListenStore,
        failInsert: Bool = true,
        deliveredWritesToFail: Int = 0,
    ) {
        self.base = base
        self.failInsert = failInsert
        self.deliveredWritesToFail = deliveredWritesToFail
    }

    func insert(_ listen: Listen) async throws -> Listen? {
        try await base.insert(listen)
    }

    func insert(_ listen: Listen, targets: [Int64]) async throws -> Listen? {
        guard !failInsert else {
            throw DatabaseError.unavailable("simulated delivery insert failure")
        }
        return try await base.insert(listen, targets: targets)
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

    func dueDeliveries(for connectionID: Int64, limit: Int, at date: Date) async throws -> [QueuedDelivery] {
        try await base.dueDeliveries(for: connectionID, limit: limit, at: date)
    }

    func deliveries(for listenID: Int64) async throws -> [Delivery] {
        try await base.deliveries(for: listenID)
    }

    func deliveries(forListenIDs listenIDs: [Int64]) async throws -> [Delivery] {
        try await base.deliveries(forListenIDs: listenIDs)
    }

    func pendingDeliveries() async throws -> [QueuedDelivery] {
        try await base.pendingDeliveries()
    }

    func markDelivered(_ deliveryID: Int64, at date: Date, reference: String?) async throws {
        guard deliveredWritesToFail == 0 else {
            deliveredWritesToFail -= 1
            throw DatabaseError.unavailable("simulated delivery state write failure")
        }
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

    func abandon(_ deliveryID: Int64, attempts: Int, lastAttemptAt: Date?, reason: String) async throws {
        try await base.abandon(deliveryID, attempts: attempts, lastAttemptAt: lastAttemptAt, reason: reason)
    }

    func markDue(for connectionID: Int64, at date: Date) async throws {
        try await base.markDue(for: connectionID, at: date)
    }

    func earliestNextAttempt(for connectionIDs: [Int64]) async throws -> Date? {
        try await base.earliestNextAttempt(for: connectionIDs)
    }
}

/// A credential store whose reads fail until the test allows them, so the
/// outbox can be shown not to treat a local Keychain error as a rejected
/// credential.
actor UnreadableCredentialStore: CredentialStore {
    private let base = MemoryCredentialStore()
    private var readsFail = true

    func credential(forConnection id: Int64) async throws -> String? {
        guard !readsFail else {
            throw DatabaseError.unavailable("simulated Keychain read failure")
        }
        return try await base.credential(forConnection: id)
    }

    func saveCredential(_ credential: String, forConnection id: Int64) async throws {
        try await base.saveCredential(credential, forConnection: id)
    }

    func deleteCredential(forConnection id: Int64) async throws {
        try await base.deleteCredential(forConnection: id)
    }

    func appCredential() async throws -> String? {
        try await base.appCredential()
    }

    func saveAppCredential(_ credential: String?) async throws {
        try await base.saveAppCredential(credential)
    }

    func allowReads() {
        readsFail = false
    }
}
