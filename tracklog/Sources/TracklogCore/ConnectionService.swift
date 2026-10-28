import Foundation

/// One line the composition root may log. It carries no credential by
/// construction, and none of its descriptions include a service message.
public enum ConnectionEvent: Equatable, Sendable, CustomStringConvertible {
    case linked(kind: ServiceKind, identity: String)
    case linkFailed(kind: ServiceKind, reason: String)

    public var description: String {
        switch self {
        case let .linked(kind, identity):
            "Linked \(kind.displayName) as \(identity)"
        case let .linkFailed(kind, reason):
            "Linking \(kind.displayName) failed: \(reason)"
        }
    }
}

/// Serializes operations that span several awaits. A load must never observe
/// or repair a link that has saved its row but not its credential or cursor.
@MainActor
private final class ConnectionOperationGate {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var hasHolder: Bool {
        isLocked
    }

    func acquire() async {
        guard isLocked else {
            isLocked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            isLocked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// The link and connection-choice flows over the connection, credential and
/// adapter ports. A link validates first, so a rejected token cannot disturb
/// an existing connection.
@MainActor
public final class ConnectionService {
    public private(set) var connections: [Connection] = []
    public private(set) var currentID: Int64?

    private let store: any ConnectionStore
    private let credentials: any CredentialStore
    private let adapters: [ServiceKind: any ServiceAdapter]
    private let clock: any Clock
    private let log: @MainActor (ConnectionEvent) -> Void
    private let gate = ConnectionOperationGate()

    public init(
        store: any ConnectionStore,
        credentials: any CredentialStore,
        adapters: [any ServiceAdapter],
        clock: any Clock,
        log: @escaping @MainActor (ConnectionEvent) -> Void = { _ in },
    ) {
        self.store = store
        self.credentials = credentials
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
                // and would block a new link to its endpoint.
                try await store.deleteConnection(id: id)
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

    /// Validates a credential, stores the connection and its credential, and
    /// makes the new connection current. A credential that cannot be saved
    /// removes the half-made connection.
    @discardableResult
    public func link(kind: ServiceKind, credential: String) async throws -> Connection {
        try await withGate {
            try await linkConnection(kind: kind, credential: credential)
        }
    }

    private func linkConnection(kind: ServiceKind, credential rawCredential: String) async throws -> Connection {
        let credential = rawCredential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !credential.isEmpty else { throw ServiceFailure.rejected("Enter a user token.") }
        guard let adapter = adapters[kind] else {
            throw ConnectionError.unsupportedService(kind)
        }

        let identity: ServiceIdentity
        do {
            identity = try await adapter.validate(credential)
        } catch let failure as ServiceFailure {
            log(.linkFailed(kind: kind, reason: Self.reason(for: failure)))
            throw failure
        } catch {
            log(.linkFailed(kind: kind, reason: "unreadable response"))
            throw ServiceFailure.retryable
        }

        let endpoint = kind.defaultEndpoint
        if connections.contains(where: { $0.kind == kind && $0.endpoint == endpoint }) {
            let failure = ConnectionError.duplicateEndpoint(kind: kind, endpoint: endpoint)
            log(.linkFailed(kind: kind, reason: "endpoint already connected"))
            throw failure
        }

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
    /// delivery's target and never scopes local history.
    public func setCurrent(_ id: Int64?) async throws {
        try await withGate {
            if let id, !connections.contains(where: { $0.id == id }) {
                throw ConnectionError.unknownConnection(id: id)
            }
            try await store.setCurrentConnectionID(id)
            currentID = id
        }
    }

    private func withGate<T>(_ operation: @MainActor () async throws -> T) async throws -> T {
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

    private static func reason(for failure: ServiceFailure) -> String {
        switch failure {
        case .auth: "authentication failed"
        case .rateLimited: "rate limited"
        case .retryable: "retryable failure"
        case .rejected: "rejected"
        }
    }
}
