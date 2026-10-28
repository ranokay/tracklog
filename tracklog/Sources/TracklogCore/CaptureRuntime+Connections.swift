import Foundation

// MARK: - Connections

extension CaptureRuntime {
    /// Loads the connections the Services page lists and the current read
    /// cursor. A read failure leaves the previous list in place and surfaces
    /// the failure; capture and local history keep running.
    func loadConnections() async {
        guard let connectionService else { return }
        do {
            try await connectionService.load()
            applyConnectionSnapshot()
            state.connectionsFailure = nil
            if state.failure?.stage == .connections {
                state.failure = nil
            }
            await reloadDeliveryState()
        } catch {
            let failure = CaptureFailure.connections(error: error)
            state.connectionsFailure = failure
            state.failure = failure
        }
    }

    func applyConnectionSnapshot() {
        guard let connectionService else { return }
        state.connections = connectionService.connections
        state.currentConnectionID = connectionService.currentID
    }
}

public extension CaptureRuntime {
    /// Reloads the Services list after a read failure.
    func reloadConnections() async {
        await loadConnections()
    }

    /// Validates a credential, stores the connection and its Keychain
    /// credential, and makes the new connection current. A failed link may
    /// still publish a kept connection when its cleanup could not complete.
    @discardableResult
    func link(kind: ServiceKind, credential: String) async throws -> Connection {
        guard let connectionService else { throw ConnectionError.unavailable }
        do {
            let connection = try await connectionService.link(kind: kind, credential: credential)
            applyConnectionSnapshot()
            await reloadDeliveryState()
            // A new credential is a delivery trigger. A new connection has no
            // earlier targets, so this never backfills older listens.
            if let id = connection.id {
                deliveryOutbox?.resume(connectionID: id)
            }
            return connection
        } catch {
            // A failed link may still have kept a recoverable connection when
            // its cleanup could not complete; publish what the service holds.
            applyConnectionSnapshot()
            throw error
        }
    }

    func setConnectionEnabled(id: Int64, enabled: Bool) async throws {
        guard let connectionService else { throw ConnectionError.unavailable }
        try await connectionService.setEnabled(id: id, enabled: enabled)
        applyConnectionSnapshot()
        await reloadDeliveryState()
        if enabled {
            // Re-enabling resumes rows that were already targeted; it does not
            // create targets for listens captured while the switch was off.
            deliveryOutbox?.resume(connectionID: id)
        }
    }

    /// Manual retry for one connection. Pending rows become due now and drain;
    /// attempts are kept.
    func retryDeliveries(forConnection id: Int64) {
        deliveryOutbox?.retry(connectionID: id)
    }

    /// Resumes a connection after a successful re-auth or credential change.
    func resumeDeliveries(forConnection id: Int64) {
        deliveryOutbox?.resume(connectionID: id)
    }

    /// A restored network path drains every eligible connection now.
    func networkBecameAvailable() {
        deliveryOutbox?.networkBecameAvailable()
    }

    /// Changes the read cursor only. It never touches a queued delivery.
    func setCurrentConnection(_ id: Int64?) async throws {
        guard let connectionService else { throw ConnectionError.unavailable }
        try await connectionService.setCurrent(id)
        applyConnectionSnapshot()
    }
}
