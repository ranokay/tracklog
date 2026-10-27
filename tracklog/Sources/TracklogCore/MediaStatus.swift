import Foundation

/// The adapter currently supplying playback observations.
///
/// Droppy's helper is the primary source. Automation for Music or Spotify is
/// the fallback; only one speaks at a time, and the helper is authoritative
/// wherever it does.
public enum MediaSourceKind: String, Equatable, Sendable {
    case helper
    case musicAutomation
    case spotifyAutomation
    case unavailable

    /// The live source as Settings names it.
    public var displayName: String {
        switch self {
        case .helper: "Droppy helper"
        case .musicAutomation: "Music via Automation"
        case .spotifyAutomation: "Spotify via Automation"
        case .unavailable: "Unavailable"
        }
    }
}

/// The media layer's runtime health, for Settings and Copy diagnostics.
///
/// The helper's init-time availability flag cannot tell a missing executable
/// from a helper that starts, exits non-zero, or reads nothing while a player
/// is playing. Those are separate states here, so each one is observable and
/// can be reported without guessing.
public struct MediaStatus: Equatable, Sendable {
    public enum HelperHealth: Equatable, Sendable {
        case unknown
        case working
        case silent
        case missingExecutable
        case spawnFailed(String)
        case exitedNonZero(Int32)
        /// The helper kept returning no payload while a scriptable player
        /// reported that it was playing.
        case silentWhilePlaying(String)
        /// No helper is configured for this source.
        case unavailable

        /// Whether the helper can speak at all. A silent helper is usable:
        /// nothing playing is a valid observation.
        public var isUsable: Bool {
            switch self {
            case .unknown, .working, .silent: true
            case .missingExecutable, .spawnFailed, .exitedNonZero, .silentWhilePlaying, .unavailable: false
            }
        }

        public var summary: String {
            switch self {
            case .unknown: "Not read yet"
            case .working: "Working"
            case .silent: "Working, nothing playing"
            case .missingExecutable: "Missing executable"
            case let .spawnFailed(message): "Could not start: \(message)"
            case let .exitedNonZero(code): "Exited with status \(code)"
            case let .silentWhilePlaying(player): "Returned nothing while \(player) was playing"
            case .unavailable: "Unavailable"
            }
        }
    }

    public enum AutomationState: Equatable, Sendable {
        case notRequested
        case available
        case denied
        case unavailable

        /// Whether Automation could still fill a silence, whether or not it
        /// has been asked for yet.
        public var isUsable: Bool {
            switch self {
            case .notRequested, .available: true
            case .denied, .unavailable: false
            }
        }

        public var summary: String {
            switch self {
            case .notRequested: "Not requested"
            case .available: "Available"
            case .denied: "Denied"
            case .unavailable: "Unavailable"
            }
        }
    }

    public let source: MediaSourceKind
    public let helperHealth: HelperHealth
    public let automation: AutomationState
    public let helperPath: String
    public let lastFailure: String?

    public init(
        source: MediaSourceKind,
        helperHealth: HelperHealth,
        automation: AutomationState,
        helperPath: String,
        lastFailure: String? = nil,
    ) {
        self.source = source
        self.helperHealth = helperHealth
        self.automation = automation
        self.helperPath = helperPath
        self.lastFailure = lastFailure
    }

    /// Whether any source could deliver a sample. A broken helper with a
    /// fallback that may still be allowed is available; when both are gone,
    /// total unavailability is the media-feed failure state.
    public var isAvailable: Bool {
        helperHealth.isUsable || automation.isUsable
    }

    /// The status a source without its own health reporting hands the
    /// runtime. Used by the test and demo sources.
    public static let legacyAvailable = MediaStatus(
        source: .helper,
        helperHealth: .working,
        automation: .notRequested,
        helperPath: "",
    )

    public static let unavailable = MediaStatus(
        source: .unavailable,
        helperHealth: .unavailable,
        automation: .unavailable,
        helperPath: "",
    )
}
