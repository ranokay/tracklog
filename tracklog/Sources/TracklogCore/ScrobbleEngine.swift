import Foundation

/// The scrobble state machine.
///
/// One session per track identity. Played time accumulates in wall-clock time
/// while the player is playing, capped at the polling gap, so a paused player
/// and a sleeping Mac do not inflate it. The threshold is
/// `max(min(percent × duration, 4 min), minimum − 0.6 s)`, with a flat 30
/// seconds when the player does not report a duration.
///
/// A session keeps the player's raw track for its identity, history row and
/// deduplication. The submitted metadata can be revised mid-play without
/// touching the played time, the threshold or now playing.
@MainActor
public final class ScrobbleEngine {
    public struct Configuration: Sendable {
        public var scrobblePercent: Double
        public var maxThreshold: TimeInterval
        public var minThreshold: TimeInterval
        /// The floor for a track whose duration the player does not report.
        /// Kept separate from `minThreshold` so changing the user's minimum
        /// duration never moves this flat fallback.
        public var unknownDurationThreshold: TimeInterval
        /// Time a track must play before now-playing is sent.
        public var settleTime: TimeInterval
        /// The coarse cross-session lock. A repeat inside this window is not
        /// scrobbled twice.
        public var dedupWindow: TimeInterval
        /// Cap on one polling gap, so a stalled feed cannot count as listening.
        public var maxSampleGap: TimeInterval
        /// A new track first seen playing this far in or less is taken to have
        /// played from its start, so those seconds count. It is the media
        /// feed's slowest poll, 15 seconds, plus room for a slow helper read.
        public var leadIn: TimeInterval = 20

        public init(
            scrobblePercent: Double = 0.5,
            maxThreshold: TimeInterval = 240,
            minThreshold: TimeInterval = 30,
            unknownDurationThreshold: TimeInterval = 30,
            settleTime: TimeInterval = 1,
            dedupWindow: TimeInterval = 8,
            maxSampleGap: TimeInterval = 5,
        ) {
            self.scrobblePercent = scrobblePercent
            self.maxThreshold = maxThreshold
            self.minThreshold = minThreshold
            self.unknownDurationThreshold = unknownDurationThreshold
            self.settleTime = settleTime
            self.dedupWindow = dedupWindow
            self.maxSampleGap = maxSampleGap
        }
    }

    private struct Session {
        /// The player's observation, and the identity every later sample and
        /// the cross-session dedup window are matched against.
        var rawTrack: Track
        /// What a scrobble and now playing would submit right now.
        var submittedTrack: Track
        var startedAt: Date
        var lastSampleAt: Date
        var lastElapsed: TimeInterval
        var played: TimeInterval
        /// When the last now-playing call went out, or `nil` if none has.
        var nowPlayingSentAt: Date?
        var scrobbled: Bool
        var cancelled: Bool
        var target: TimeInterval
        /// The playing state of the last observation, so a pause followed by
        /// playing is recognised as a resume.
        var isPlaying: Bool
    }

    public private(set) var status: ScrobbleStatus = .idle

    /// The longest a now playing may stay on a service before a resume
    /// refreshes it, independent of the scrobble threshold cap.
    private static let nowPlayingStaleCap: TimeInterval = 240

    private var configuration: Configuration
    private var session: Session?
    private var lastScrobble: (identity: String, at: Date)?

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// The player's raw track for the session in flight, or `nil` when no
    /// session is armed. This is the source for an in-flight edit, not the
    /// processed metadata the widget shows.
    public var currentRawTrack: Track? {
        session?.rawTrack
    }

    /// Feeds one observation and returns the effects it caused.
    ///
    /// `submitted` is the metadata a scrobble should carry, when the caller
    /// has run the metadata pipeline. It is only a revision: it never changes
    /// the session identity, played time, threshold or now playing.
    /// `nowPlayingEnabled` is the user's toggle at sample time: with it off,
    /// no now playing goes out and none is recorded as sent.
    public func ingest(
        _ sample: MediaSample?,
        submitted: Track? = nil,
        nowPlayingEnabled: Bool = true,
    ) -> [ScrobbleEffect] {
        let now = sample?.observedAt ?? Date()

        guard let sample, !sample.track.isEmpty else {
            let effects = finalize(at: now)
            session = nil
            status = .idle
            return effects
        }

        var effects: [ScrobbleEffect] = []

        if let current = session, current.rawTrack.identity != sample.track.identity {
            effects += finalize(at: now)
            session = nil
        }

        if session == nil {
            let inLeadIn = sample.isPlaying && sample.elapsed <= configuration.leadIn
            session = makeSession(
                sample,
                submitted: submitted,
                startedAt: now.addingTimeInterval(-max(0, min(sample.elapsed, 3600))),
                played: inLeadIn ? max(0, sample.elapsed) : 0,
                at: now,
            )
        }

        guard var current = session else { return effects }

        let wasPlaying = current.isPlaying
        current = advance(current, with: sample, submitted: submitted, at: now)
        current.target = threshold(for: sample.track.duration)

        effects += nowPlayingEffects(
            for: &current,
            resumed: sample.isPlaying && !wasPlaying,
            duration: sample.track.duration,
            enabled: nowPlayingEnabled,
            at: now,
        )
        effects += scrobbleEffects(for: &current, at: now)

        session = current
        publish(current)
        return effects
    }

    /// Revises what the current session will submit without resetting played
    /// time, the threshold or now playing. The raw identity is untouched.
    public func reviseSubmittedTrack(_ track: Track) {
        guard var current = session, !current.scrobbled else { return }
        current.submittedTrack = track
        session = current
    }

    /// Suppresses the current session's scrobble and history row until the
    /// track changes, restarts or is undone. It is ineffective once the
    /// threshold has fired.
    @discardableResult
    public func cancelCurrentSession() -> Bool {
        guard var current = session, !current.scrobbled, !current.cancelled else { return false }
        current.cancelled = true
        session = current
        publish(current)
        return true
    }

    /// Re-enables a cancelled session from the played time it already has.
    @discardableResult
    public func undoCancelCurrentSession() -> Bool {
        guard var current = session, !current.scrobbled, current.cancelled else { return false }
        current.cancelled = false
        session = current
        publish(current)
        return true
    }

    public func reset() {
        session = nil
        lastScrobble = nil
        status = .idle
    }

    /// Moves the threshold floor without touching the 4-minute cap or the
    /// percentage. The current session picks it up with its next sample.
    public func setMinimumThreshold(_ seconds: TimeInterval) {
        configuration.minThreshold = seconds
    }

    private func makeSession(
        _ sample: MediaSample,
        submitted: Track?,
        startedAt: Date,
        played: TimeInterval,
        at now: Date,
    ) -> Session {
        Session(
            rawTrack: sample.track,
            submittedTrack: submitted ?? sample.track,
            startedAt: startedAt,
            lastSampleAt: now,
            lastElapsed: sample.elapsed,
            played: played,
            nowPlayingSentAt: nil,
            scrobbled: false,
            cancelled: false,
            target: threshold(for: sample.track.duration),
            isPlaying: sample.isPlaying,
        )
    }

    private func advance(
        _ session: Session,
        with sample: MediaSample,
        submitted: Track?,
        at now: Date,
    ) -> Session {
        // A jump back to the first seconds of the same track is a restart,
        // not a seek: start a fresh session so a repeat can scrobble again.
        if sample.elapsed + 3 < session.lastElapsed, sample.elapsed < 3 {
            return makeSession(
                sample,
                submitted: submitted,
                startedAt: now,
                played: max(0, sample.elapsed),
                at: now,
            )
        }

        var current = session
        current.submittedTrack = submitted ?? current.submittedTrack
        if sample.isPlaying {
            let gap = max(0, min(now.timeIntervalSince(current.lastSampleAt), configuration.maxSampleGap))
            let rate = max(0, min(sample.playbackRate, 4))
            current.played += gap * (rate > 0 ? rate : 1)
        }
        current.lastSampleAt = now
        current.lastElapsed = sample.elapsed
        current.isPlaying = sample.isPlaying
        return current
    }

    private func nowPlayingEffects(
        for current: inout Session,
        resumed: Bool,
        duration: TimeInterval,
        enabled: Bool,
        at now: Date,
    ) -> [ScrobbleEffect] {
        guard enabled, current.isPlaying else { return [] }

        let isDue = if let sentAt = current.nowPlayingSentAt {
            // A resume refreshes a stale now playing. A seek, a pause or a
            // revision never does, and a pause never withdraws one.
            resumed && now.timeIntervalSince(sentAt) > staleWindow(for: duration)
        } else {
            current.played >= configuration.settleTime
        }
        guard isDue else { return [] }

        current.nowPlayingSentAt = now
        return [.nowPlaying(current.submittedTrack)]
    }

    private func scrobbleEffects(for current: inout Session, at now: Date) -> [ScrobbleEffect] {
        guard !current.cancelled, !current.scrobbled, current.played >= current.target else { return [] }
        current.scrobbled = true
        guard !isDuplicate(current.rawTrack.identity, at: now) else { return [] }

        lastScrobble = (current.rawTrack.identity, now)
        return [
            .scrobble(
                Scrobble(
                    raw: current.rawTrack,
                    submitted: current.submittedTrack,
                    playedAt: current.startedAt,
                    playedDuration: current.played,
                ),
            ),
        ]
    }

    private func publish(_ current: Session) {
        status = ScrobbleStatus(
            phase: current.scrobbled ? .scrobbled : .armed,
            track: current.rawTrack,
            played: current.played,
            target: current.target,
            isPlaying: current.isPlaying,
            isCancelled: current.cancelled,
        )
    }

    private func finalize(at now: Date) -> [ScrobbleEffect] {
        guard let current = session, !current.scrobbled, !current.cancelled,
              current.played >= current.target,
              !isDuplicate(current.rawTrack.identity, at: now) else { return [] }
        lastScrobble = (current.rawTrack.identity, now)
        return [
            .scrobble(
                Scrobble(
                    raw: current.rawTrack,
                    submitted: current.submittedTrack,
                    playedAt: current.startedAt,
                    playedDuration: current.played,
                ),
            ),
        ]
    }

    private func isDuplicate(_ identity: String, at now: Date) -> Bool {
        guard let lastScrobble else { return false }
        return lastScrobble.identity == identity
            && now.timeIntervalSince(lastScrobble.at) < configuration.dedupWindow
    }

    private func threshold(for duration: TimeInterval) -> TimeInterval {
        guard duration > 0 else { return configuration.unknownDurationThreshold }
        return max(
            min(duration * configuration.scrobblePercent, configuration.maxThreshold),
            configuration.minThreshold - 0.6,
        )
    }

    /// How old the last now-playing must be for a resume to refresh it: three
    /// quarters of the duration, capped at four minutes. An unknown duration
    /// has a zero window, so every resume refreshes it.
    private func staleWindow(for duration: TimeInterval) -> TimeInterval {
        min(max(0, duration) * 0.75, Self.nowPlayingStaleCap)
    }
}
