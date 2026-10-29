import Foundation

/// One service adapter's declared limits. The outbox reads the batch size and
/// the read layer reads the rest; both come from the same port.
public struct ServiceCapabilities: Equatable, Sendable {
    public let supportsNowPlaying: Bool
    public let maximumBatchSize: Int
    public let supportsLove: Bool
    public let supportsHate: Bool
    public let supportsDelete: Bool
    /// Whether this protocol signs its requests (Last.fm, unlike ListenBrainz).
    public let signsRequests: Bool
    /// The least time between two requests to the same connection. ListenBrainz
    /// and Libre.fm keep one second; Last.fm has no client-side spacing rule.
    public let minimumRequestInterval: TimeInterval

    public init(
        supportsNowPlaying: Bool = false,
        maximumBatchSize: Int = 1,
        supportsLove: Bool = false,
        supportsHate: Bool = false,
        supportsDelete: Bool = false,
        signsRequests: Bool = false,
        minimumRequestInterval: TimeInterval = 0,
    ) {
        self.supportsNowPlaying = supportsNowPlaying
        self.maximumBatchSize = max(1, maximumBatchSize)
        self.supportsLove = supportsLove
        self.supportsHate = supportsHate
        self.supportsDelete = supportsDelete
        self.signsRequests = signsRequests
        self.minimumRequestInterval = max(0, minimumRequestInterval)
    }
}

/// The account identifier a service reports for a credential.
public struct ServiceIdentity: Equatable, Sendable {
    public let name: String
    public let displayName: String

    public init(name: String, displayName: String? = nil) {
        self.name = name
        self.displayName = displayName ?? name
    }
}

/// Why Last.fm rejected the application's own credentials rather than the
/// listener's session. The Services page shows the reason so the remedy is not
/// mistaken for a broken account.
public enum AppCredentialProblem: String, Equatable, Sendable {
    case missing
    case invalidKey
    case suspendedKey
    case invalidSignature

    public var title: String {
        switch self {
        case .missing: "Last.fm app credentials are missing"
        case .invalidKey: "Last.fm rejected the app key"
        case .suspendedKey: "Last.fm suspended the app key"
        case .invalidSignature: "Last.fm rejected the request signature"
        }
    }

    public var detail: String {
        switch self {
        case .missing:
            "No Last.fm API key and shared secret are configured. "
                + "Last.fm sign-in and scrobbling will fail until a working pair is saved "
                + "on the Last.fm app credentials page."
        case .invalidKey:
            "Last.fm did not accept the app key in use. "
                + "Save a working pair on the Last.fm app credentials page."
        case .suspendedKey:
            "Last.fm suspended the app key in use. It will not accept requests until the key "
                + "is restored or a different pair is saved."
        case .invalidSignature:
            "Last.fm did not accept the request signature. "
                + "Check that the API key and shared secret belong together, then save the pair again."
        }
    }
}

/// The one failure taxonomy every service response maps to.
public enum ServiceFailure: Error, Equatable, Sendable, LocalizedError {
    /// The service rejected the credential.
    case auth
    /// The service rejected the application's own credentials, not the
    /// listener's session.
    case appCredentialAuth(AppCredentialProblem)
    /// Too many requests. `retryAfter` is the server's hint, in seconds.
    case rateLimited(retryAfter: TimeInterval?)
    /// A transport, server or malformed-response failure worth retrying.
    case retryable
    /// The service refused the operation for a reason a retry cannot fix.
    case rejected(String?)

    /// Whether the connection must sign in again. An application-credential
    /// rejection is an auth failure too: reconnecting alone will not fix it,
    /// but the connection still stops delivering.
    public var isAuthentication: Bool {
        switch self {
        case .auth, .appCredentialAuth: true
        case .rateLimited, .retryable, .rejected: false
        }
    }

    /// The app-credential problem when this is one. The delivery and link
    /// paths share one pattern match instead of repeating it.
    var appCredentialProblem: AppCredentialProblem? {
        guard case let .appCredentialAuth(problem) = self else { return nil }
        return problem
    }

    public var errorDescription: String? {
        switch self {
        case .auth:
            "The service did not accept that token."
        case let .appCredentialAuth(problem):
            "\(problem.title). \(problem.detail)"
        case let .rateLimited(retryAfter):
            if let retryAfter, retryAfter > 0 {
                "The service is rate limiting requests. Try again in \(Int(retryAfter.rounded(.up))) seconds."
            } else {
                "The service is rate limiting requests. Try again shortly."
            }
        case .retryable:
            "The service could not be reached. Check your connection and try again."
        case let .rejected(message):
            message ?? "The service rejected that request."
        }
    }
}

/// The one adapter port every service implements. Operations are typed
/// methods; a response maps to ``ServiceFailure``.
public protocol ServiceAdapter: Sendable {
    var kind: ServiceKind { get }
    var capabilities: ServiceCapabilities { get }
    /// Checks a credential with the service and returns the identity it names.
    func validate(_ credential: String) async throws -> ServiceIdentity
}

/// The delivery half of a service adapter. A thrown failure backs off the
/// whole batch; per-item outcomes let one rejection leave the rest alone.
public protocol DeliveryAdapter: ServiceAdapter {
    /// Submits one batch, oldest listen first, and returns one outcome per
    /// listen in the same order.
    func submit(
        _ listens: [Listen],
        connection: Connection,
        credential: String,
    ) async throws -> [DeliveryResult]

    /// Sends one now playing. Returns the service reference it names, when the
    /// service answers with one. Never queued, retried or persisted.
    func submitNowPlaying(
        _ track: Track,
        connection: Connection,
        credential: String,
    ) async throws -> String?
}
