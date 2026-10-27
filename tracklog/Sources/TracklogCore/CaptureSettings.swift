import Foundation

/// The user-facing capture switches, persisted by the composition root.
///
/// A pause has an end, so it survives a relaunch instead of being a runtime
/// flag. The minimum duration is the engine's threshold floor for a track with
/// a known duration, not a pre-filter: a shorter track can still now-play. A
/// track whose duration the player does not report keeps the engine's flat
/// 30-second floor.
public struct CaptureSettings: Equatable, Sendable {
    public static let minimumDurationRange: ClosedRange<TimeInterval> = 30 ... 300
    public static let defaultMinimumDuration: TimeInterval = 30

    public var scrobblingEnabled: Bool
    public var nowPlayingEnabled: Bool
    /// End of the current pause, or `nil` when capture is not paused.
    public var pausedUntil: Date?
    public var minimumDuration: TimeInterval

    public init(
        scrobblingEnabled: Bool = false,
        nowPlayingEnabled: Bool = true,
        pausedUntil: Date? = nil,
        minimumDuration: TimeInterval = CaptureSettings.defaultMinimumDuration,
    ) {
        self.scrobblingEnabled = scrobblingEnabled
        self.nowPlayingEnabled = nowPlayingEnabled
        self.pausedUntil = pausedUntil
        self.minimumDuration = min(
            max(minimumDuration, Self.minimumDurationRange.lowerBound),
            Self.minimumDurationRange.upperBound,
        )
    }
}
