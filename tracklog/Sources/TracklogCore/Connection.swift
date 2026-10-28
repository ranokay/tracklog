import Foundation

/// One authenticated identity at one service endpoint. The credential is not
/// part of the record: it lives in the credential store, keyed by `id`.
public struct Connection: Identifiable, Equatable, Sendable {
    /// Assigned by the store. `nil` until the connection has been persisted.
    public let id: Int64?
    public let kind: ServiceKind
    /// The normalized service root this identity belongs to.
    public let endpoint: ServiceEndpoint
    /// The account identifier the service reported, scoped to the endpoint.
    public let identity: String
    public let displayName: String
    /// Gates now playing and this connection's deliveries. On at link.
    public var isEnabled: Bool
    public var authState: ConnectionAuthState
    public let createdAt: Date
    public var lastUsedAt: Date

    public init(
        id: Int64? = nil,
        kind: ServiceKind,
        endpoint: ServiceEndpoint,
        identity: String,
        displayName: String? = nil,
        isEnabled: Bool = true,
        authState: ConnectionAuthState = .signedIn,
        createdAt: Date,
        lastUsedAt: Date? = nil,
    ) {
        self.id = id
        self.kind = kind
        self.endpoint = endpoint
        self.identity = identity
        self.displayName = displayName ?? identity
        self.isEnabled = isEnabled
        self.authState = authState
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt ?? createdAt
    }

    public func stored(withID id: Int64) -> Connection {
        Connection(
            id: id,
            kind: kind,
            endpoint: endpoint,
            identity: identity,
            displayName: displayName,
            isEnabled: isEnabled,
            authState: authState,
            createdAt: createdAt,
            lastUsedAt: lastUsedAt,
        )
    }
}

/// What the Services list shows for a connection: connected, paused by its
/// own switch, or waiting for the same identity to sign in again.
public enum ConnectionStatus: String, Equatable, Sendable {
    case connected
    case paused
    case needsSignIn = "needs-sign-in"

    public var displayName: String {
        switch self {
        case .connected: "Connected"
        case .paused: "Paused"
        case .needsSignIn: "Needs sign-in"
        }
    }
}

public extension Connection {
    var status: ConnectionStatus {
        if authState == .needsSignIn {
            return .needsSignIn
        }
        return isEnabled ? .connected : .paused
    }
}

/// Whether the service still accepts the stored credential. A rejected
/// credential keeps the connection and its identity; it never unlinks it.
public enum ConnectionAuthState: String, Sendable {
    case signedIn = "signed-in"
    case needsSignIn = "needs-sign-in"
}

/// A connection failure the Services page can show inline. It can never carry
/// a credential: nothing in this type has a field for one.
public enum ConnectionError: Error, Equatable, Sendable, LocalizedError {
    case unavailable
    case unsupportedService(ServiceKind)
    case duplicateEndpoint(kind: ServiceKind, endpoint: ServiceEndpoint)
    case unknownConnection(id: Int64)
    case credentialStorage
    case currentCursor

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            "Tracklog's service storage is unavailable."
        case let .unsupportedService(kind):
            "Linking \(kind.displayName) is not available yet."
        case let .duplicateEndpoint(kind, endpoint):
            "\(kind.displayName) is already connected at \(endpoint)."
        case .unknownConnection:
            "That connection is no longer available."
        case .credentialStorage:
            "The token could not be saved in the Keychain."
        case .currentCursor:
            "The connection could not be made current. Try again."
        }
    }
}
