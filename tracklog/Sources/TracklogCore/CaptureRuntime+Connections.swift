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
        refreshFeedbackSupport()
        invalidateSignInRecoveries()
        evaluateSignInHUD()
        scheduleStuckEvaluation()
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
    func link(
        kind: ServiceKind,
        credential: String,
        endpoint: ServiceEndpoint? = nil,
    ) async throws -> Connection {
        guard let connectionService else { throw ConnectionError.unavailable }
        return try await publishLinkedConnection {
            try await connectionService.link(kind: kind, credential: credential, endpoint: endpoint)
        }
    }

    /// Stores a credential the caller already verified, such as the Last.fm
    /// session key from the browser flow. The connection still starts enabled
    /// and current, and the outbox resumes it.
    @discardableResult
    func linkVerified(
        kind: ServiceKind,
        credential: String,
        identity: ServiceIdentity,
        endpoint: ServiceEndpoint? = nil,
    ) async throws -> Connection {
        guard let connectionService else { throw ConnectionError.unavailable }
        return try await publishLinkedConnection {
            try await connectionService.linkVerified(
                kind: kind,
                credential: credential,
                identity: identity,
                endpoint: endpoint,
            )
        }
    }

    /// Publishes a linked connection, refreshes the delivery state and triggers
    /// its first drain. A failed link still publishes a recoverable connection
    /// when its cleanup could not complete.
    private func publishLinkedConnection(
        _ operation: @MainActor () async throws -> Connection,
    ) async throws -> Connection {
        do {
            let connection = try await operation()
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

    /// Signs an existing connection in again. A same-identity sign-in clears
    /// needs sign-in, keeps pending deliveries and drains them now; a different
    /// identity asks through `confirmReplacement`, abandons the old pending
    /// deliveries and takes over the connection.
    @discardableResult
    func reauthenticate(
        id: Int64,
        credential: String,
        identity: ServiceIdentity? = nil,
        confirmReplacement: @MainActor (Connection, ServiceIdentity, Int) -> Bool,
    ) async throws -> Connection {
        guard let connectionService else { throw ConnectionError.unavailable }
        let wasNeedingSignIn = state.connection(id: id)?.authState == .needsSignIn
        // No drain may read the old rows and then submit them with the new
        // account's credential. The worker is stopped before the service call
        // and resumed either way.
        deliveryOutbox?.suspend(connectionID: id)
        let connection: Connection
        do {
            connection = try await connectionService.reauthenticate(
                id: id,
                credential: credential,
                identity: identity,
                confirmReplacement: confirmReplacement,
            )
        } catch {
            // The connection may still be linked with its old credential, so
            // return it to its normal schedule.
            deliveryOutbox?.resume(connectionID: id)
            throw error
        }
        if wasNeedingSignIn, connection.authState == .signedIn {
            hudTracking.signInRecoveries[id] = SignInRecovery(
                identity: connection.identity,
                delivered: 0,
            )
        }
        applyConnectionSnapshot()
        await reloadDeliveryState()
        // A re-auth is a delivery trigger. Held rows become due now regardless
        // of the backoff the rejection scheduled, then drain oldest first.
        deliveryOutbox?.retry(connectionID: id)
        return connection
    }

    /// Removes a connection, abandons its pending deliveries and stops its
    /// drain. Local history stays; a re-link never resumes abandoned rows.
    @discardableResult
    func unlinkConnection(id: Int64) async throws -> UnlinkedConnection {
        guard let connectionService else { throw ConnectionError.unavailable }
        // Stop new batches before the credential goes away. An in-flight
        // request may still finish; nothing after it is sent.
        deliveryOutbox?.suspend(connectionID: id)
        let unlinked: UnlinkedConnection
        do {
            unlinked = try await connectionService.unlink(id: id)
        } catch {
            // The connection is still linked, so let its normal schedule run.
            deliveryOutbox?.resume(connectionID: id)
            throw error
        }
        deliveryOutbox?.connectionRemoved(connectionID: id)
        applyConnectionSnapshot()
        await reloadDeliveryState()
        return unlinked
    }

    /// How many deliveries the unlink confirmation will abandon. A read failure
    /// is surfaced rather than shown as zero, because the confirm dialog would
    /// then understate what unlink destroys.
    func pendingDeliveryCount(forConnection id: Int64) async throws -> Int {
        guard let deliveryStore else { return 0 }
        return try await deliveryStore.pendingDeliveryCount(forConnection: id)
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
