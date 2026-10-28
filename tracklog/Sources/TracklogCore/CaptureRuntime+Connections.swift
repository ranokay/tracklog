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
        } catch {
            let failure = CaptureFailure.connections(error: error)
            state.connectionsFailure = failure
            state.failure = failure
        }
    }

    private func applyConnectionSnapshot() {
        guard let connectionService else { return }
        state.connections = connectionService.connections
        state.currentConnectionID = connectionService.currentID
        state.connectionsFailure = nil
        if state.failure?.stage == .connections {
            state.failure = nil
        }
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
    }

    /// Changes the read cursor only. It never touches a queued delivery.
    func setCurrentConnection(_ id: Int64?) async throws {
        guard let connectionService else { throw ConnectionError.unavailable }
        try await connectionService.setCurrent(id)
        applyConnectionSnapshot()
    }
}
