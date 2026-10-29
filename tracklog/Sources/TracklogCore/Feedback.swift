import Foundation

/// The local knowledge of what the listener did with a track. It is keyed by
/// the processed metadata identity, never by the source player.
public enum FeedbackScore: String, Equatable, Sendable {
    case loved
    case hated
}

/// One track's local feedback and when the listener last changed it.
public struct TrackFeedback: Equatable, Sendable {
    public let identity: String
    public let score: FeedbackScore
    public let updatedAt: Date

    public init(identity: String, score: FeedbackScore, updatedAt: Date) {
        self.identity = identity
        self.score = score
        self.updatedAt = updatedAt
    }
}

/// The one user action a surface can request. Unlove removes local feedback
/// and resets the service score.
public enum FeedbackAction: String, Equatable, Sendable {
    case love
    case unlove
    case hate
}

extension FeedbackAction {
    /// The local score this action records, or nil for the unlove reset.
    var localScore: FeedbackScore? {
        switch self {
        case .love: .loved
        case .unlove: nil
        case .hate: .hated
        }
    }
}

/// A recording reference a service returned. The delivery row keeps the MSID a
/// now playing answered with; metadata lookup resolves an MBID for one action.
public enum RecordingReference: Equatable, Sendable {
    case msid(String)
    case mbid(String)
}

/// Which track a feedback action targets, so a history row can never borrow
/// the current track's recording reference.
public enum FeedbackScope: Equatable, Sendable {
    case listen(Int64)
    case currentTrack
}

/// Which feedback actions the current connection set can perform.
public struct FeedbackSupport: Equatable, Sendable {
    public let canLove: Bool
    public let canHate: Bool

    public init(canLove: Bool = false, canHate: Bool = false) {
        self.canLove = canLove
        self.canHate = canHate
    }
}

/// The feedback half of a service adapter. Last.fm and Libre.fm use their
/// love/unlove dialects; ListenBrainz uses the recording feedback endpoint and
/// resolves a missing recording reference through metadata lookup.
public protocol FeedbackAdapter: ServiceAdapter {
    /// Whether a feedback call needs a recording reference. Last.fm's
    /// artist/title call does not.
    var requiresReference: Bool { get }
    /// Resolves a recording reference at action time. Returns `nil` when the
    /// service does not need one.
    func resolveReference(
        for track: Track,
        connection: Connection,
        credential: String,
    ) async throws -> RecordingReference?
    /// Sends one feedback action. The caller supplies a reference when one is
    /// known; the adapter never borrows one from another track.
    func submitFeedback(
        _ action: FeedbackAction,
        track: Track,
        reference: RecordingReference?,
        connection: Connection,
        credential: String,
    ) async throws
}

public extension FeedbackAdapter {
    var requiresReference: Bool {
        false
    }

    func resolveReference(
        for _: Track,
        connection _: Connection,
        credential _: String,
    ) async throws -> RecordingReference? {
        nil
    }
}

/// Durable local feedback. The SQLite store is the production implementation;
/// tests drive the real schema in a temporary container.
public protocol FeedbackStore: Sendable {
    /// The stored feedback for the requested processed identities.
    func feedback(for identities: [String]) async throws -> [String: TrackFeedback]

    /// Stores one score, or removes the row when `score` is nil.
    func setFeedback(_ score: FeedbackScore?, for identity: String, at date: Date) async throws
}
