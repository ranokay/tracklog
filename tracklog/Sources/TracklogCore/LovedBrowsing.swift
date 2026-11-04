import Foundation

/// Where the next loved page starts. Last.fm and GNU FM page by number;
/// ListenBrainz pages by raw feedback offset, which includes rows this app
/// could not name.
public enum LovedCursor: Equatable, Sendable {
    case page(Int)
    case offset(Int)
}

/// One currently-loved track from the current connection. The service returns
/// current love state only; a row's presence means the account loves the track
/// now, not that a love event happened at a given time.
public struct LovedRow: Identifiable, Equatable, Sendable {
    /// The source connection the row was read from. The feedback reference is
    /// valid only there, and another connection must resolve its own.
    public let connectionID: Int64?
    public let id: String
    public let title: String
    public let artist: String
    public let album: String
    /// A recording identifier the source service supplied, when it supplies
    /// one. Last.fm and GNU FM love by artist and title instead.
    public let reference: RecordingReference?

    public init(
        connectionID: Int64?,
        id: String,
        title: String,
        artist: String,
        album: String = "",
        reference: RecordingReference? = nil,
    ) {
        self.connectionID = connectionID
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.reference = reference
    }

    /// The processed fields a feedback action uses. Album is the service's
    /// release name when it supplied one, so the feedback identity matches a
    /// local listen carrying the same album.
    public var track: Track {
        Track(title: title, artist: artist, album: album)
    }

    /// The identity the feedback store and the now-playing strip use.
    public var trackIdentity: String {
        ListenMetadata(track).identity
    }
}

public struct LovedServicePage: Equatable, Sendable {
    public let rows: [LovedRow]
    /// Feedback or loved entries the service returned without enough metadata
    /// to name. They still count toward a ListenBrainz offset.
    public let omitted: Int
    public let nextCursor: LovedCursor?

    public init(rows: [LovedRow], omitted: Int = 0, nextCursor: LovedCursor?) {
        self.rows = rows
        self.omitted = omitted
        self.nextCursor = nextCursor
    }
}

/// A compatible server that does not implement the read. It is not a
/// transient failure, so the view offers a connection remedy instead of a
/// retry that cannot succeed.
public enum LovedServiceError: Error, Equatable, Sendable {
    case unsupported(String?)
}

public protocol LovedServiceReading: Sendable {
    var kind: ServiceKind { get }
    /// The first cursor this service reads. Last.fm starts at page 1;
    /// ListenBrainz starts at offset 0.
    var firstCursor: LovedCursor { get }
    func loved(
        connection: Connection,
        credential: String,
        cursor: LovedCursor,
        limit: Int,
    ) async throws -> LovedServicePage
}

/// Why the current connection's loved list could not be read. A read failure
/// never changes the connection's stored auth state; the delivery/feedback
/// outbox owns that transition.
public enum LovedSignInProblem: Equatable, Sendable {
    case signedOut
    case credentialMissing
    case credentialUnavailable
}

public enum LovedFailure: Equatable, Sendable {
    case needsSignIn(LovedSignInProblem)
    case appCredentials(AppCredentialProblem)
    case rateLimited(retryAfter: TimeInterval?)
    case offline
    case service(String)
}

public enum LovedPhase: Equatable, Sendable {
    case idle
    case loading
    case ready
    case empty
    /// The read succeeded, but every returned recording lacked the metadata
    /// needed to name it. This is not an empty account.
    case metadataUnavailable
    case unavailable(String)
    case failed(LovedFailure)
}

/// One failed row action. The row stays; the notice names the service that
/// did not confirm the change.
public struct LovedActionFailure: Equatable, Sendable {
    public let rowID: String
    public let message: String

    public init(rowID: String, message: String) {
        self.rowID = rowID
        self.message = message
    }
}

public struct LovedViewState: Equatable, Sendable {
    public var phase: LovedPhase = .idle
    public var rows: [LovedRow] = []
    public var sourceLabel: String?
    public var omitted = 0
    public var hasMore = false
    public var isLoadingMore = false
    public var loadMoreFailure: LovedFailure?
    public var refreshFailure: LovedFailure?
    /// The earliest a rate-limited connection may be read again.
    public var retryNotBefore: Date?
    public var canUnlove = false
    public var unloveUnavailableReason: String?
    public var actionFailure: LovedActionFailure?

    public init() {}
}

// MARK: - Copy

public enum LovedCopy {
    public static let noConnection =
        "Loved tracks come from the current connection. Choose Last.fm, Libre.fm or "
            + "ListenBrainz in the switcher above, or connect one on Services."

    public static func unavailableForKind(_ kind: ServiceKind) -> String {
        "\(kind.displayName) has no loved-track read. Choose a Last.fm, Libre.fm or "
            + "ListenBrainz connection."
    }

    public static func empty(service: String) -> String {
        "No loved tracks on \(service). Tracks you love there appear here."
    }

    public static func omittedOnly(service: String, count: Int) -> String {
        "\(service) has loved recordings for this account, but none of the first "
            + "\(count) could be matched to track metadata."
    }

    public static func omittedNote(count: Int) -> String {
        "\(count) loved \(count == 1 ? "recording" : "recordings") could not be shown "
            + "because the service has no track metadata for them."
    }

    public static func sourceLabel(_ connection: Connection) -> String {
        "\(connection.kind.displayName) · \(connection.displayName)"
    }

    public static func paused(service: String) -> String {
        "\(service) is paused. Turn it on in Services to unlove tracks."
    }

    public static func signIn(service: String) -> String {
        "\(service) needs sign-in. Sign in on Services to unlove tracks."
    }

    public static func unsupportedLove(service: String) -> String {
        "\(service) does not support love."
    }

    public static func rateLimited(service: String) -> String {
        "\(service) is rate limiting requests. Unloving will resume after the wait."
    }

    public static func actionFailure(title: String, service: String) -> String {
        "Could not unlove “\(title)” on \(service). The service did not confirm the change."
    }

    public static func failureMessage(
        _ failure: LovedFailure,
        service: String,
        retryAt: Date?,
    ) -> String {
        switch failure {
        case let .needsSignIn(problem):
            switch problem {
            case .signedOut:
                "\(service) needs sign-in. Sign in on Services to browse its loved tracks."
            case .credentialMissing:
                "The saved \(service) credential is missing. Sign in on Services."
            case .credentialUnavailable:
                "Tracklog could not read the saved credential. Unlock the login keychain, then try again."
            }
        case let .appCredentials(problem):
            "\(problem.title). \(problem.detail)"
        case let .rateLimited(retryAfter):
            if let retryAt, retryAfter != nil {
                "\(service) is rate limiting requests. Try again after "
                    + "\(retryAt.formatted(date: .omitted, time: .shortened))."
            } else {
                "\(service) is rate limiting requests. Try again shortly."
            }
        case .offline:
            "\(service) could not be reached. Check your connection and try again."
        case let .service(message):
            message
        }
    }

    public static var refreshFailure: String {
        "Could not refresh loved tracks. Showing the last loaded list."
    }

    public static var loadMoreFailure: String {
        "More loved tracks could not be loaded."
    }
}

public extension LovedFailure {
    var needsSettings: Bool {
        if case .appCredentials = self {
            return true
        }
        return false
    }

    var needsServices: Bool {
        switch self {
        case .needsSignIn:
            true
        default:
            false
        }
    }

    var isAuthentication: Bool {
        switch self {
        case .needsSignIn, .appCredentials:
            true
        default:
            false
        }
    }
}
