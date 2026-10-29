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

    /// Reports presence, never the pair. A corrupt slot is treated as no
    /// override, the same way the provider treats it.
    func loadLastFMAppCredentials() async {
        state.lastFMCompiledCredentialsPresent = compiledLastFMAppCredentials.isConfigured
        guard let credentialStore else {
            state.lastFMOverridePresent = false
            return
        }
        state.lastFMOverridePresent = await credentialStore.lastFMAppCredentialOverride() != nil
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
        return try await publishLinkedConnection {
            try await connectionService.link(kind: kind, credential: credential)
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
    ) async throws -> Connection {
        guard let connectionService else { throw ConnectionError.unavailable }
        return try await publishLinkedConnection {
            try await connectionService.linkVerified(
                kind: kind,
                credential: credential,
                identity: identity,
            )
        }
    }

    /// Records why Last.fm rejected the project's own app credentials. The
    /// reason survives a relaunch so Services can still explain a held queue.
    func noteLastFMAppCredentialProblem(_ problem: AppCredentialProblem) {
        state.lastFMAppCredentialProblem = problem
        persistAppCredentialProblem?(problem)
    }

    /// Clears the app-credential warning after a successful link or delivery.
    func clearLastFMAppCredentialProblem() {
        state.lastFMAppCredentialProblem = nil
        persistAppCredentialProblem?(nil)
    }

    /// The pair the next signed Last.fm call would use. Callers that expose it
    /// must not show or log it.
    func effectiveLastFMAppCredentials() async -> LastFMAppCredentials? {
        guard let credentialStore else { return nil }
        return await StoredLastFMAppCredentials(
            credentials: credentialStore,
            compiled: compiledLastFMAppCredentials,
        ).appCredentials()
    }

    /// Checks a candidate pair with Last.fm, then saves it in the Keychain.
    /// A changed pair invalidates every Last.fm session key: every Last.fm
    /// connection becomes needs sign-in and its pending deliveries stay
    /// queued until it reconnects.
    func saveLastFMAppCredentialOverride(apiKey: String, sharedSecret: String) async throws {
        guard let override = LastFMAppCredentialOverride(
            validating: apiKey,
            sharedSecret: sharedSecret,
        ) else {
            throw LastFMAppCredentialError.incomplete
        }
        guard let credentialStore else { throw ConnectionError.unavailable }
        guard let lastFMAppCredentialsValidator else {
            throw ConnectionError.unsupportedService(.lastFM)
        }

        let provider = StoredLastFMAppCredentials(
            credentials: credentialStore,
            compiled: compiledLastFMAppCredentials,
        )
        let previous = await provider.appCredentials()
        // Validate before writing anything: a rejected pair must leave the
        // connection list and the old credentials untouched.
        try await lastFMAppCredentialsValidator.validateAppCredentials(override.credentials)
        do {
            try await credentialStore.saveLastFMAppCredentialOverride(override)
        } catch {
            throw LastFMAppCredentialError.storage
        }
        await loadLastFMAppCredentials()
        clearLastFMAppCredentialProblem()
        if override.credentials != previous {
            try await signOutLastFMSessions()
        }
    }

    /// Clears the Keychain override and returns to the compiled pair. Removing
    /// a pair also changes the credentials, so every Last.fm session is
    /// invalidated the same way.
    func removeLastFMAppCredentialOverride() async throws {
        guard let credentialStore else { throw ConnectionError.unavailable }
        let provider = StoredLastFMAppCredentials(
            credentials: credentialStore,
            compiled: compiledLastFMAppCredentials,
        )
        let previous = await provider.appCredentials()
        guard await provider.override() != nil else { return }
        do {
            try await credentialStore.saveLastFMAppCredentialOverride(nil)
        } catch {
            throw LastFMAppCredentialError.storage
        }
        await loadLastFMAppCredentials()
        // An override that repeated the compiled pair never changed the
        // effective credentials, so removing it invalidates nothing.
        guard await provider.appCredentials() != previous else { return }
        clearLastFMAppCredentialProblem()
        try await signOutLastFMSessions()
    }

    private func signOutLastFMSessions() async throws {
        guard let connectionService else { return }
        do {
            try await connectionService.markNeedsSignIn(kind: .lastFM)
            applyConnectionSnapshot()
            await reloadDeliveryState()
        } catch {
            // Publish the rows that did change before reporting the failure.
            applyConnectionSnapshot()
            throw error
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
