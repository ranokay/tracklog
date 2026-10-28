import Foundation
import TracklogCore

/// Asks for Automation lazily, through the host, and remembers a denial.
///
/// The production gate lives in the droplet because only it holds
/// `host.permissions` and `host.preferences`. The arbiter asks this gate only
/// at the first moment the fallback is needed, never at activation.
@MainActor
public protocol MediaAutomationPermissionGate: AnyObject {
    /// Reads the current decision without prompting. A remembered denial is
    /// reported as `.denied` even when TCC would ask again.
    func authorization() -> MediaStatus.AutomationState
    /// Asks the host for the permission. Only called from a fallback.
    func requestAuthorization() async -> MediaStatus.AutomationState
    /// Persists a denial so a later launch does not prompt again.
    func rememberDenial()
}

/// Produces one now-playing stream from the helper and the Automation
/// fallback.
///
/// The helper is authoritative wherever it speaks. Automation is probed only
/// while the helper is silent, at most once per candidate on the idle
/// cadence, and only when the candidate app is already running. A source
/// switch for the same track does not emit a gap, so the capture session is
/// not reset.
@MainActor
public final class MediaArbiter: NowPlayingSource {
    /// Two seconds while a player is playing. The research found this
    /// defensible; a flat one-second loop is not.
    public static let playingInterval: Duration = .seconds(2)
    /// Five seconds while paused or idle.
    public static let idleInterval: Duration = .seconds(5)
    /// One Automation probe per candidate at the idle cadence.
    public static let automationProbeInterval: TimeInterval = 5
    /// While Automation is the playing source, its next sample must land
    /// inside the engine's five-second sample gap, so probe at the playing
    /// cadence.
    private static let automationPlayingProbeInterval: TimeInterval = 2

    public private(set) var mediaStatus: MediaStatus

    let helper: any MediaHelperReading
    private let automation: any MediaAutomationProbing
    private let candidates: [MediaAutomationCandidate]
    private let playerIsRunning: MediaPlayerRunningCheck
    private let permissions: any MediaAutomationPermissionGate
    private let now: @MainActor () -> Date
    private let sleeper: @MainActor (Duration) async -> Void

    private var sampleHandler: (@MainActor (MediaSample?) -> Void)?
    private var statusHandler: (@MainActor (MediaStatus) -> Void)?
    private var loopTask: Task<Void, Never>?
    private var activeCandidate: MediaAutomationCandidate?
    private var activeCandidateIsPlaying = false
    private var lastAutomationProbe: Date?
    private var lastEmittedSample: MediaSample?
    private var lastPublishedStatus: MediaStatus?

    public init(
        helper: any MediaHelperReading,
        permissions: any MediaAutomationPermissionGate,
        automation: any MediaAutomationProbing = AppleScriptAutomationProbe(),
        candidates: [MediaAutomationCandidate] = MediaAutomationCandidate.defaults,
        playerIsRunning: @escaping MediaPlayerRunningCheck = { MediaPlayerProcess.isRunning($0) },
        now: @escaping @MainActor () -> Date = { Date() },
        sleeper: @escaping @MainActor (Duration) async -> Void = { interval in
            try? await Task.sleep(for: interval)
        },
    ) {
        self.helper = helper
        self.automation = automation
        self.candidates = candidates
        self.playerIsRunning = playerIsRunning
        self.permissions = permissions
        self.now = now
        self.sleeper = sleeper

        let present = helper.isExecutable
        let health: MediaStatus.HelperHealth = present ? .unknown : .missingExecutable
        mediaStatus = MediaStatus(
            source: present ? .helper : .unavailable,
            helperHealth: health,
            automation: .notRequested,
            helperPath: helper.executablePath,
            lastFailure: present ? nil : "Media helper is missing.",
        )
    }

    // MARK: - NowPlayingSource

    public func start(
        onSample: @escaping @MainActor (MediaSample?) -> Void,
        onStatus: @escaping @MainActor (MediaStatus) -> Void,
    ) {
        guard loopTask == nil else { return }
        sampleHandler = onSample
        statusHandler = onStatus
        lastPublishedStatus = mediaStatus
        onStatus(mediaStatus)

        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let poll = await pollOnce()
                guard !Task.isCancelled else { return }
                switch poll.emission {
                case .none:
                    break
                case let .sample(sample):
                    sampleHandler?(sample)
                }
                await sleeper(poll.interval)
            }
        }
    }

    public func stop() {
        loopTask?.cancel()
        loopTask = nil
        sampleHandler = nil
        statusHandler = nil
        activeCandidate = nil
        activeCandidateIsPlaying = false
        lastAutomationProbe = nil
        lastEmittedSample = nil
        lastPublishedStatus = nil
    }

    /// One poll, exposed so tests and manual diagnostics can drive the
    /// arbiter without the loop.
    @discardableResult
    public func pollOnce() async -> MediaPoll {
        let read = await helper.read()
        guard !Task.isCancelled else {
            return MediaPoll(emission: .none, interval: Self.idleInterval, status: mediaStatus)
        }
        applyHelper(read)

        let emission: MediaPoll.Emission
        if case let .sample(sample) = read {
            activeCandidate = nil
            activeCandidateIsPlaying = false
            setStatus(source: .helper)
            emission = emit(sample)
        } else {
            emission = await pollFallback()
        }

        let interval = lastEmittedSample?.isPlaying == true
            ? Self.playingInterval
            : Self.idleInterval
        publishStatus()
        return MediaPoll(emission: emission, interval: interval, status: mediaStatus)
    }

    // MARK: - Health

    private func applyHelper(_ read: MediaHelperRead) {
        let health: MediaStatus.HelperHealth = if case .empty = read,
                                                  let activeCandidate,
                                                  activeCandidateIsPlaying {
            .silentWhilePlaying(activeCandidate.displayName)
        } else {
            read.health
        }
        setStatus(helperHealth: health, lastFailure: failure(for: health, readFailure: read.failure))
    }

    /// A silent-while-playing health is itself a failure, even though the
    /// helper read succeeded. Keep it in diagnostics.
    private func failure(
        for health: MediaStatus.HelperHealth,
        readFailure: String? = nil,
    ) -> String? {
        if case let .silentWhilePlaying(player) = health {
            return "Media helper returned no track while \(player) was playing."
        }
        return readFailure
    }

    private var helperIsUsable: Bool {
        mediaStatus.helperHealth.isUsable
    }

    private func silentWhilePlaying(_ candidate: MediaAutomationCandidate) -> MediaStatus.HelperHealth {
        switch mediaStatus.helperHealth {
        case .silent, .silentWhilePlaying: .silentWhilePlaying(candidate.displayName)
        default: mediaStatus.helperHealth
        }
    }

    // MARK: - Plumbing

    private func setStatus(
        source: MediaSourceKind? = nil,
        helperHealth: MediaStatus.HelperHealth? = nil,
        automation: MediaStatus.AutomationState? = nil,
        lastFailure: String? = nil,
    ) {
        mediaStatus = MediaStatus(
            source: source ?? mediaStatus.source,
            helperHealth: helperHealth ?? mediaStatus.helperHealth,
            automation: automation ?? mediaStatus.automation,
            helperPath: helper.executablePath,
            lastFailure: lastFailure ?? mediaStatus.lastFailure,
        )
    }

    /// A nil sample stops now playing; it is emitted once, and only after a
    /// live observation.
    private func emit(_ sample: MediaSample?) -> MediaPoll.Emission {
        if sample == nil, lastEmittedSample == nil {
            return .none
        }
        lastEmittedSample = sample
        return .sample(sample)
    }

    private func publishStatus() {
        guard mediaStatus != lastPublishedStatus else { return }
        lastPublishedStatus = mediaStatus
        statusHandler?(mediaStatus)
    }
}

// MARK: - Fallback

private extension MediaArbiter {
    func pollFallback() async -> MediaPoll.Emission {
        // A silent helper (including a valid empty read) is the trigger the
        // spec gives for detection. A helper that is speaking never reaches
        // this path, so it never asks for Automation. The probe is what tells
        // us whether a scriptable player reports playing.
        let running = candidates.filter { playerIsRunning($0.bundleID) }
        if running.isEmpty {
            return clearAutomation()
        }

        guard isAutomationProbeDue else {
            // Keep the last observation until the next idle tick: a source
            // switch for the same track must not reset the session.
            if activeCandidate == nil {
                setStatus(source: helperIsUsable ? .helper : .unavailable)
            }
            return .none
        }
        lastAutomationProbe = now()

        guard await ensureAutomationReady() else {
            return clearAutomation()
        }
        guard !Task.isCancelled else { return .none }

        if let sample = await firstAutomationSample(in: running) {
            return emit(sample)
        }
        return clearAutomation()
    }

    func firstAutomationSample(in running: [MediaAutomationCandidate]) async -> MediaSample? {
        var pausedActive: MediaSample?

        for candidate in running {
            switch await automation.probe(candidate) {
            case let .playing(sample):
                guard !Task.isCancelled else { return nil }
                activeCandidate = candidate
                activeCandidateIsPlaying = true
                let health = silentWhilePlaying(candidate)
                setStatus(
                    source: candidate.sourceKind,
                    helperHealth: health,
                    automation: .available,
                    lastFailure: failure(for: health),
                )
                return sample
            case .paused:
                if candidate == activeCandidate, let paused = pausedSample(for: candidate) {
                    pausedActive = paused
                }
                continue
            case .stopped, .notRunning:
                continue
            case .denied:
                rememberDenialIfNeeded()
                return nil
            case let .failed(message):
                setStatus(lastFailure: "\(candidate.displayName) via Automation failed: \(message)")
                continue
            }
        }

        if let pausedActive, let activeCandidate {
            activeCandidateIsPlaying = false
            let health: MediaStatus.HelperHealth = if case .silentWhilePlaying = mediaStatus.helperHealth {
                .silent
            } else {
                mediaStatus.helperHealth
            }
            setStatus(
                source: activeCandidate.sourceKind,
                helperHealth: health,
                automation: .available,
            )
            return pausedActive
        }
        return nil
    }

    /// A paused Automation source keeps its last observation and reports the
    /// pause, so the engine holds the session instead of finalizing it.
    func pausedSample(for candidate: MediaAutomationCandidate) -> MediaSample? {
        guard let last = lastEmittedSample, last.track.bundleID == candidate.bundleID else { return nil }
        return MediaSample(
            track: last.track,
            elapsed: last.elapsed,
            playbackRate: 0,
            isPlaying: false,
            timestamp: now(),
        )
    }

    func clearAutomation() -> MediaPoll.Emission {
        let wasActive = activeCandidate != nil
        activeCandidate = nil
        activeCandidateIsPlaying = false
        let health: MediaStatus.HelperHealth = if case .silentWhilePlaying = mediaStatus.helperHealth {
            .silent
        } else {
            mediaStatus.helperHealth
        }
        setStatus(
            source: health.isUsable ? .helper : .unavailable,
            helperHealth: health,
        )
        return wasActive || lastEmittedSample != nil ? emit(nil) : .none
    }

    var isAutomationProbeDue: Bool {
        guard let lastAutomationProbe else { return true }
        let interval = activeCandidateIsPlaying
            ? Self.automationPlayingProbeInterval
            : Self.automationProbeInterval
        return now().timeIntervalSince(lastAutomationProbe) >= interval
    }

    func ensureAutomationReady() async -> Bool {
        switch permissions.authorization() {
        case .available:
            setStatus(automation: .available)
            return true
        case .notRequested:
            switch await permissions.requestAuthorization() {
            case .available:
                setStatus(automation: .available)
                return true
            case .denied:
                markAutomationDenied()
                return false
            case .unavailable:
                setStatus(automation: .unavailable, lastFailure: "Automation is unavailable in this host.")
                return false
            case .notRequested:
                setStatus(automation: .notRequested)
                return false
            }
        case .denied:
            markAutomationDenied()
            return false
        case .unavailable:
            setStatus(automation: .unavailable, lastFailure: "Automation is unavailable in this host.")
            return false
        }
    }

    func markAutomationDenied() {
        setStatus(automation: .denied, lastFailure: "Automation permission was denied.")
    }

    /// A probe's AppleScript error is the one denial the permission service
    /// did not already persist; remember it so the next launch does not ask.
    func rememberDenialIfNeeded() {
        if mediaStatus.automation != .denied {
            permissions.rememberDenial()
        }
        markAutomationDenied()
    }
}

/// Whether a candidate app is running. The arbiter checks this before any
/// probe, so an AppleScript that would launch a closed app is never sent.
public typealias MediaPlayerRunningCheck = @MainActor (String) -> Bool
