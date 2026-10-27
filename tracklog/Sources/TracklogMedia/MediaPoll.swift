import Foundation
import TracklogCore

/// What one arbiter poll produced.
public struct MediaPoll: Equatable, Sendable {
    public enum Emission: Equatable, Sendable {
        /// No observation to publish; the last one still stands.
        case none
        /// A sample, or `nil` when playback stopped.
        case sample(MediaSample?)
    }

    public let emission: Emission
    /// How long the poll loop waits before the next pass.
    public let interval: Duration
    public let status: MediaStatus

    public init(emission: Emission, interval: Duration, status: MediaStatus) {
        self.emission = emission
        self.interval = interval
        self.status = status
    }
}
