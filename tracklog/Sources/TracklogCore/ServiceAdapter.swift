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

    public init(
        supportsNowPlaying: Bool = false,
        maximumBatchSize: Int = 1,
        supportsLove: Bool = false,
        supportsHate: Bool = false,
        supportsDelete: Bool = false,
        signsRequests: Bool = false,
    ) {
        self.supportsNowPlaying = supportsNowPlaying
        self.maximumBatchSize = max(1, maximumBatchSize)
        self.supportsLove = supportsLove
        self.supportsHate = supportsHate
        self.supportsDelete = supportsDelete
        self.signsRequests = signsRequests
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

/// The one failure taxonomy every service response maps to.
public enum ServiceFailure: Error, Equatable, Sendable, LocalizedError {
    /// The service rejected the credential.
    case auth
    /// Too many requests. `retryAfter` is the server's hint, in seconds.
    case rateLimited(retryAfter: TimeInterval?)
    /// A transport, server or malformed-response failure worth retrying.
    case retryable
    /// The service refused the operation for a reason a retry cannot fix.
    case rejected(String?)

    public var errorDescription: String? {
        switch self {
        case .auth:
            "The service did not accept that token."
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
