import Foundation

/// The link and connection-choice flows over the connection, credential and
/// adapter ports. A link validates first, so a rejected token cannot disturb
/// an existing connection.
@MainActor
public final class ConnectionService {
    public internal(set) var connections: [Connection] = []
    public internal(set) var currentID: Int64?

    let store: any ConnectionStore
    let credentials: any CredentialStore
    let deliveries: (any DeliveryStore)?
    let adapters: [ServiceKind: any ServiceAdapter]
    let clock: any Clock
    let log: @MainActor (ConnectionEvent) -> Void
    let gate = ConnectionOperationGate()

    public init(
        store: any ConnectionStore,
        credentials: any CredentialStore,
        deliveries: (any DeliveryStore)? = nil,
        adapters: [any ServiceAdapter],
        clock: any Clock,
        log: @escaping @MainActor (ConnectionEvent) -> Void = { _ in },
    ) {
        self.store = store
        self.credentials = credentials
        self.deliveries = deliveries
        self.clock = clock
        self.log = log
        var byKind: [ServiceKind: any ServiceAdapter] = [:]
        for adapter in adapters {
            byKind[adapter.kind] = adapter
        }
        self.adapters = byKind
    }

    public var currentConnection: Connection? {
        connections.first { $0.id == currentID }
    }

    /// Test seam for the serialization regression: fired when an operation
    /// joins the gate behind a holder.
    var onGateWait: (@MainActor () -> Void)?

    /// Loads the durable connections and repairs any credentialless orphan.
    /// Serialized with `link()` so it never observes a half-made link.
    public func load() async throws {
        try await withGate {
            try await loadConnections()
        }
    }

    private func loadConnections() async throws {
        var loaded: [Connection] = []
        for connection in try await store.connections() {
            guard let id = connection.id else {
                loaded.append(connection)
                continue
            }
            let credential: String?
            do {
                credential = try await credentials.credential(forConnection: id)
            } catch {
                // An unreadable credential is not proof it is missing.
                loaded.append(connection)
                continue
            }
            guard credential == nil else {
                loaded.append(connection)
                continue
            }
            do {
                // A row left by a failed credential save has no usable secret
                // and would block a new link to its endpoint. The cleanup and
                // its queue abandonment commit together when the store can.
                if let atomicStore = store as? any ConnectionUnlinkStore {
                    _ = try await atomicStore.unlinkConnection(
                        id: id,
                        reason: Self.lostCredentialReason,
                    )
                } else {
                    try await deliveries?.abandonPending(
                        forConnection: id,
                        reason: Self.lostCredentialReason,
                    )
                    try await store.deleteConnection(id: id)
                }
            } catch {
                var orphan = connection
                orphan.authState = .needsSignIn
                loaded.append(orphan)
            }
        }

        let persistedCurrent = try await store.currentConnectionID()
        connections = loaded
        guard let persistedCurrent, loaded.contains(where: { $0.id == persistedCurrent }) else {
            currentID = nil
            if persistedCurrent != nil {
                try? await store.setCurrentConnectionID(nil)
            }
            return
        }
        currentID = persistedCurrent
    }

    public func setEnabled(id: Int64, enabled: Bool) async throws {
        try await withGate {
            guard let index = connections.firstIndex(where: { $0.id == id }) else {
                throw ConnectionError.unknownConnection(id: id)
            }
            var updated = connections[index]
            updated.isEnabled = enabled
            let stored = try await store.save(updated)
            connections[index] = stored
        }
    }

    /// Marks a connection whose credential the service rejected. It keeps its
    /// identity and its pending deliveries; a later sign-in resumes them.
    @discardableResult
    public func markNeedsSignIn(id: Int64) async throws -> Connection {
        try await setAuthState(id: id, .needsSignIn)
    }

    /// Clears a rejected credential after the same identity signs in again.
    @discardableResult
    public func markSignedIn(id: Int64) async throws -> Connection {
        try await setAuthState(id: id, .signedIn)
    }

    private func setAuthState(id: Int64, _ state: ConnectionAuthState) async throws -> Connection {
        try await withGate {
            guard let index = connections.firstIndex(where: { $0.id == id }) else {
                throw ConnectionError.unknownConnection(id: id)
            }
            guard connections[index].authState != state else {
                return connections[index]
            }
            var updated = connections[index]
            updated.authState = state
            let stored = try await store.save(updated)
            connections[index] = stored
            return stored
        }
    }

    /// Persists the current-connection read cursor. It never changes a queued
    /// delivery's target and never scopes local history. Choosing a connection
    /// counts as using it, so an unlink falls back to the most recently chosen
    /// one.
    public func setCurrent(_ id: Int64?) async throws {
        try await withGate {
            guard let id else {
                try await store.setCurrentConnectionID(nil)
                currentID = nil
                return
            }
            guard let index = connections.firstIndex(where: { $0.id == id }) else {
                throw ConnectionError.unknownConnection(id: id)
            }
            var selected = connections[index]
            selected.lastUsedAt = clock.now
            connections[index] = try await store.save(selected)
            try await store.setCurrentConnectionID(id)
            currentID = id
        }
    }

    func withGate<T>(_ operation: @MainActor () async throws -> T) async throws -> T {
        if gate.hasHolder {
            onGateWait?()
        }
        await gate.acquire()
        do {
            let result = try await operation()
            gate.release()
            return result
        } catch {
            gate.release()
            throw error
        }
    }
}

public extension ConnectionService {
    /// Marks every connection of one kind as needing sign-in, as when the
    /// application's own credentials change and every stored session key stops
    /// matching. Pending deliveries stay queued; the outbox's eligibility gate
    /// holds them until each connection signs in again.
    func markNeedsSignIn(kind: ServiceKind) async throws {
        try await withGate {
            var firstError: (any Error)?
            for index in connections.indices where connections[index].kind == kind {
                var connection = connections[index]
                connection.authState = .needsSignIn
                // Publish the state before the write so a storage failure still
                // holds this connection's deliveries for the rest of the run.
                connections[index] = connection
                do {
                    // Write even a connection already in memory as needs-sign-in:
                    // a previous write may have failed, and this call is the retry.
                    connections[index] = try await store.save(connection)
                } catch {
                    firstError = firstError ?? error
                }
            }
            if let firstError {
                throw firstError
            }
        }
    }
}

/// A link log line's reason. It names the failure class, never a credential.
func connectionFailureReason(_ failure: ServiceFailure) -> String {
    switch failure {
    case .auth: "authentication failed"
    case .appCredentialAuth: "app credentials rejected"
    case .rateLimited: "rate limited"
    case .retryable: "retryable failure"
    case .rejected: "rejected"
    }
}

// MARK: - Link

extension ConnectionService {
    /// Validates a credential, stores the connection and its credential, and
    /// makes the new connection current. A credential that cannot be saved
    /// removes the half-made connection. `endpoint` is the root a
    /// configurable service was linked against; `nil` uses the kind's default.
    @discardableResult
    public func link(
        kind: ServiceKind,
        credential: String,
        endpoint: ServiceEndpoint? = nil,
    ) async throws -> Connection {
        try await withGate {
            try await linkConnection(kind: kind, credential: credential, endpoint: endpoint)
        }
    }

    /// Stores a credential whose identity the caller already verified, such as
    /// the session key Last.fm returns from `auth.getSession`. The adapter must
    /// still exist for the kind; this only skips the duplicate validation call.
    @discardableResult
    public func linkVerified(
        kind: ServiceKind,
        credential: String,
        identity: ServiceIdentity,
        endpoint: ServiceEndpoint? = nil,
    ) async throws -> Connection {
        try await withGate {
            try await linkConnection(
                kind: kind,
                credential: credential,
                endpoint: endpoint,
                identity: identity,
            )
        }
    }

    private func linkConnection(
        kind: ServiceKind,
        credential rawCredential: String,
        endpoint: ServiceEndpoint?,
        identity verifiedIdentity: ServiceIdentity? = nil,
    ) async throws -> Connection {
        let credential = rawCredential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !credential.isEmpty else { throw ServiceFailure.rejected("Enter a user token.") }
        guard let adapter = adapters[kind] else {
            throw ConnectionError.unsupportedService(kind)
        }
        let endpoint = endpoint ?? kind.defaultEndpoint

        let identity: ServiceIdentity
        if let verifiedIdentity {
            identity = verifiedIdentity
        } else {
            do {
                identity = try await adapter.validate(credential, endpoint: endpoint)
            } catch let failure as ServiceFailure {
                log(.linkFailed(kind: kind, reason: connectionFailureReason(failure)))
                throw failure
            } catch {
                log(.linkFailed(kind: kind, reason: "unreadable response"))
                throw ServiceFailure.retryable
            }
        }

        if connections.contains(where: { $0.kind == kind && $0.endpoint == endpoint }) {
            let failure = ConnectionError.duplicateEndpoint(kind: kind, endpoint: endpoint)
            log(.linkFailed(kind: kind, reason: "endpoint already connected"))
            throw failure
        }

        // A page that leaves while the token is being exchanged cancels its
        // task. Do not start a link the caller no longer wants.
        try Task.checkCancellation()

        let now = clock.now
        let candidate = Connection(
            kind: kind,
            endpoint: endpoint,
            identity: identity.name,
            displayName: identity.displayName,
            isEnabled: true,
            authState: .signedIn,
            createdAt: now,
            lastUsedAt: now,
        )
        let stored: Connection
        do {
            stored = try await store.save(candidate)
        } catch {
            log(.linkFailed(kind: kind, reason: "connection storage failed"))
            throw error
        }
        guard let id = stored.id else {
            throw ConnectionError.unavailable
        }

        try await persistCredentialAndCursor(
            credential: credential,
            connection: stored,
            id: id,
            kind: kind,
        )
        // Cancellation may have landed after the row was written. Remove the
        // half-made link rather than keeping a connection the page abandoned.
        if Task.isCancelled {
            try? await credentials.deleteCredential(forConnection: id)
            try? await store.deleteConnection(id: id)
            throw CancellationError()
        }
        currentID = id
        connections.append(stored)
        log(.linked(kind: kind, identity: identity.name))
        return stored
    }

    /// Saves the credential and sets the cursor as one link. If either step
    /// fails, the half-made connection is removed or kept visible for repair.
    private func persistCredentialAndCursor(
        credential: String,
        connection: Connection,
        id: Int64,
        kind: ServiceKind,
    ) async throws {
        do {
            try await credentials.saveCredential(credential, forConnection: id)
        } catch {
            do {
                try await store.deleteConnection(id: id)
            } catch {
                // The row has no usable credential. load() repairs it on the
                // next activation so it cannot block a relink.
            }
            log(.linkFailed(kind: kind, reason: "credential storage failed"))
            throw ConnectionError.credentialStorage
        }

        // A connection that cannot be made current is not a usable link:
        // remove the half-made row and its credential, then report failure.
        do {
            try await store.setCurrentConnectionID(id)
        } catch {
            var kept = false
            do {
                try await credentials.deleteCredential(forConnection: id)
            } catch {
                // The credential is still there, so the row is usable and
                // stays discoverable for a later cursor choice.
                kept = true
            }
            if !kept {
                do {
                    try await store.deleteConnection(id: id)
                } catch {
                    // The credential is already gone; load() repairs the
                    // credentialless row on the next activation.
                }
            }
            if kept {
                connections.append(connection)
            }
            log(.linkFailed(kind: kind, reason: "current connection could not be saved"))
            throw ConnectionError.currentCursor
        }
    }
}
