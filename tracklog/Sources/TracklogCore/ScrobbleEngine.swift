import Foundation

/// The scrobble state machine.
///
/// One session per track identity. Played time accumulates in wall-clock time
/// while the player is playing, capped at the polling gap, so a paused player
/// and a sleeping Mac do not inflate it. The threshold is Pano's:
/// `max(min(percent × duration, 4 min), minimum − 0.6 s)`, with a flat 30
/// seconds when the player does not report a duration.
@MainActor
public final class ScrobbleEngine {
    public struct Configuration: Sendable {
        public var scrobblePercent: Double
        public var maxThreshold: TimeInterval
        public var minThreshold: TimeInterval
        /// Time a track must play before now-playing is sent.
        public var settleTime: TimeInterval
        /// The coarse cross-session lock. A repeat inside this window is not
        /// scrobbled twice.
        public var dedupWindow: TimeInterval
        /// Cap on one polling gap, so a stalled feed cannot count as listening.
        public var maxSampleGap: TimeInterval

        public init(
            scrobblePercent: Double = 0.5,
            maxThreshold: TimeInterval = 240,
            minThreshold: TimeInterval = 30,
            settleTime: TimeInterval = 1,
            dedupWindow: TimeInterval = 8,
            maxSampleGap: TimeInterval = 5
        ) {
            self.scrobblePercent = scrobblePercent
            self.maxThreshold = maxThreshold
            self.minThreshold = minThreshold
            self.settleTime = settleTime
            self.dedupWindow = dedupWindow
            self.maxSampleGap = maxSampleGap
        }
    }

    private struct Session {
        var track: Track
        var startedAt: Date
        var lastSampleAt: Date
        var lastElapsed: TimeInterval
        var played: TimeInterval
        var nowPlayingSent: Bool
        var scrobbled: Bool
        var target: TimeInterval
    }

    public private(set) var status: ScrobbleStatus = .idle

    private let configuration: Configuration
    private var session: Session?
    private var lastScrobble: (identity: String, at: Date)?

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Feeds one observation and returns the effects it caused.
    public func ingest(_ sample: MediaSample?) -> [ScrobbleEffect] {
        let now = sample?.timestamp ?? Date()

        guard let sample, !sample.track.isEmpty else {
            let effects = finalize(at: now)
            session = nil
            status = .idle
            return effects
        }

        var effects: [ScrobbleEffect] = []

        if let current = session, current.track.identity != sample.track.identity {
            effects += finalize(at: now)
            session = nil
        }

        if session == nil {
            session = Session(
                track: sample.track,
                startedAt: now.addingTimeInterval(-max(0, min(sample.elapsed, 3600))),
                lastSampleAt: now,
                lastElapsed: sample.elapsed,
                played: 0,
                nowPlayingSent: false,
                scrobbled: false,
                target: threshold(for: sample.track.duration)
            )
        }

        guard var current = session else { return effects }

        // A jump back to the first seconds of the same track is a restart,
        // not a seek: start a fresh session so a repeat can scrobble again.
        if sample.elapsed + 3 < current.lastElapsed, sample.elapsed < 3 {
            current = Session(
                track: sample.track,
                startedAt: now,
                lastSampleAt: now,
                lastElapsed: sample.elapsed,
                played: max(0, sample.elapsed),
                nowPlayingSent: false,
                scrobbled: false,
                target: threshold(for: sample.track.duration)
            )
        } else {
            if sample.isPlaying {
                let gap = max(0, min(now.timeIntervalSince(current.lastSampleAt), configuration.maxSampleGap))
                let rate = max(0, min(sample.playbackRate, 4))
                current.played += gap * (rate > 0 ? rate : 1)
            }
            current.lastSampleAt = now
            current.lastElapsed = sample.elapsed
        }

        current.target = threshold(for: sample.track.duration)

        if !current.nowPlayingSent, sample.isPlaying, current.played >= configuration.settleTime {
            current.nowPlayingSent = true
            effects.append(.nowPlaying(current.track))
        }

        if !current.scrobbled, current.played >= current.target {
            current.scrobbled = true
            if !isDuplicate(current.track.identity, at: now) {
                lastScrobble = (current.track.identity, now)
                effects.append(
                    .scrobble(
                        Scrobble(
                            track: current.track,
                            playedAt: current.startedAt,
                            playedDuration: current.played
                        )
                    )
                )
            }
        }

        session = current
        status = ScrobbleStatus(
            phase: current.scrobbled ? .scrobbled : .armed,
            track: current.track,
            played: current.played,
            target: current.target,
            isPlaying: sample.isPlaying
        )
        return effects
    }

    public func reset() {
        session = nil
        lastScrobble = nil
        status = .idle
    }

    private func finalize(at now: Date) -> [ScrobbleEffect] {
        guard let current = session, !current.scrobbled, current.played >= current.target,
              !isDuplicate(current.track.identity, at: now) else { return [] }
        lastScrobble = (current.track.identity, now)
        return [
            .scrobble(
                Scrobble(
                    track: current.track,
                    playedAt: current.startedAt,
                    playedDuration: current.played
                )
            )
        ]
    }

    private func isDuplicate(_ identity: String, at now: Date) -> Bool {
        guard let lastScrobble else { return false }
        return lastScrobble.identity == identity
            && now.timeIntervalSince(lastScrobble.at) < configuration.dedupWindow
    }

    private func threshold(for duration: TimeInterval) -> TimeInterval {
        guard duration > 0 else { return configuration.minThreshold }
        return max(
            min(duration * configuration.scrobblePercent, configuration.maxThreshold),
            configuration.minThreshold - 0.6
        )
    }
}
