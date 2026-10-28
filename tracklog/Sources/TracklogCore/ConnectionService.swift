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

    public func load() async throws {
        let loaded = try await store.connections()
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
    public func link(kind: ServiceKind, credential rawCredential: String) async throws -> Connection {
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

        do {
            try await credentials.saveCredential(credential, forConnection: id)
        } catch {
            try? await store.deleteConnection(id: id)
            log(.linkFailed(kind: kind, reason: "credential storage failed"))
            throw ConnectionError.credentialStorage
        }

        // A connection that cannot be made current is not a usable link:
        // remove the half-made row and its credential, then report failure.
        do {
            try await store.setCurrentConnectionID(id)
        } catch {
            try? await credentials.deleteCredential(forConnection: id)
            try? await store.deleteConnection(id: id)
            log(.linkFailed(kind: kind, reason: "current connection could not be saved"))
            throw ConnectionError.currentCursor
        }
        currentID = id
        connections.append(stored)
        log(.linked(kind: kind, identity: identity.name))
        return stored
    }

    public func setEnabled(id: Int64, enabled: Bool) async throws {
        guard let index = connections.firstIndex(where: { $0.id == id }) else {
            throw ConnectionError.unknownConnection(id: id)
        }
        var updated = connections[index]
        updated.isEnabled = enabled
        let stored = try await store.save(updated)
        connections[index] = stored
    }

    /// Persists the current-connection read cursor. It never changes a queued
    /// delivery's target and never scopes local history.
    public func setCurrent(_ id: Int64?) async throws {
        if let id, !connections.contains(where: { $0.id == id }) {
            throw ConnectionError.unknownConnection(id: id)
        }
        try await store.setCurrentConnectionID(id)
        currentID = id
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
