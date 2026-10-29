import Foundation

/// Durable connections and the current-connection read cursor. The SQLite
/// store is the production implementation; tests drive their own.
public protocol ConnectionStore: Sendable {
    /// Every connection, in link order.
    func connections() async throws -> [Connection]
    /// Inserts a connection, or updates one by its id. A new connection whose
    /// kind and normalized endpoint already exist is refused; the pair is
    /// unique.
    func save(_ connection: Connection) async throws -> Connection
    /// Deletes one connection. Deleting the current connection clears the
    /// cursor. An unknown id is a no-op.
    func deleteConnection(id: Int64) async throws
    /// The current connection's id, or `nil` when none is chosen.
    func currentConnectionID() async throws -> Int64?
    /// Persists the current connection. `nil` clears it. An unknown id is
    /// refused rather than silently ignored.
    func setCurrentConnectionID(_ id: Int64?) async throws
}

/// A connection store that can remove a connection and abandon its pending
/// deliveries in one durable operation, so a failure leaves both unchanged.
public protocol ConnectionUnlinkStore: Sendable {
    /// Abandons every waiting or retrying delivery for the connection, deletes
    /// the connection, and clears the cursor when it pointed at it. Returns the
    /// number of abandoned rows. A thrown error rolls everything back.
    func unlinkConnection(id: Int64, reason: String) async throws -> Int
}
