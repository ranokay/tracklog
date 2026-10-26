import Foundation

/// One track, as the media feed describes it.
public struct Track: Equatable, Sendable {
    public let title: String
    public let artist: String
    public let album: String
    public let duration: TimeInterval
    /// Bundle identifier of the app that owns the player, when known.
    public let bundleID: String

    public init(
        title: String,
        artist: String = "",
        album: String = "",
        duration: TimeInterval = 0,
        bundleID: String = ""
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.bundleID = bundleID
    }

    /// The identity a scrobble session is keyed on.
    ///
    /// Case and surrounding whitespace are noise: the same listen can arrive
    /// spelled two ways between two polls.
    public var identity: String {
        [title, artist, album, bundleID]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .joined(separator: "\u{1F}")
    }

    public var isEmpty: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// One observation of the system's now-playing feed.
public struct MediaSample: Equatable, Sendable {
    public let track: Track
    /// Playback position reported by the player, in seconds.
    public let elapsed: TimeInterval
    /// `1` while playing normally; `0` while paused.
    public let playbackRate: Double
    public let isPlaying: Bool
    public let timestamp: Date

    public init(
        track: Track,
        elapsed: TimeInterval,
        playbackRate: Double,
        isPlaying: Bool,
        timestamp: Date = Date()
    ) {
        self.track = track
        self.elapsed = elapsed
        self.playbackRate = playbackRate
        self.isPlaying = isPlaying
        self.timestamp = timestamp
    }
}

/// A listen that met the threshold and should reach the services.
public struct Scrobble: Equatable, Sendable {
    public let track: Track
    /// When the track started, not when the threshold fired.
    public let playedAt: Date
    public let playedDuration: TimeInterval

    public init(track: Track, playedAt: Date, playedDuration: TimeInterval) {
        self.track = track
        self.playedAt = playedAt
        self.playedDuration = playedDuration
    }
}

/// What the engine asks its owner to do after one observation.
public enum ScrobbleEffect: Equatable, Sendable {
    case nowPlaying(Track)
    case scrobble(Scrobble)
}

/// What the widget and settings pane render.
public struct ScrobbleStatus: Equatable, Sendable {
    public enum Phase: String, Sendable {
        case idle
        case armed
        case scrobbled
    }

    public let phase: Phase
    public let track: Track?
    public let played: TimeInterval
    public let target: TimeInterval
    public let isPlaying: Bool

    public init(phase: Phase, track: Track?, played: TimeInterval, target: TimeInterval, isPlaying: Bool) {
        self.phase = phase
        self.track = track
        self.played = played
        self.target = target
        self.isPlaying = isPlaying
    }

    public static let idle = ScrobbleStatus(
        phase: .idle,
        track: nil,
        played: 0,
        target: 0,
        isPlaying: false
    )

    public var remaining: TimeInterval {
        max(0, target - played)
    }

    public var progress: Double {
        guard target > 0 else { return 0 }
        return min(1, max(0, played / target))
    }
}
