import Foundation

// MARK: - Lifecycle

public extension CaptureRuntime {
    func stop() {
        pauseTask?.cancel()
        pauseTask = nil
        deliveryRefreshTask?.cancel()
        deliveryRefreshTask = nil
        stuckEvaluationTask?.cancel()
        stuckEvaluationTask = nil
        hudTracking.primed = false
        feedbackChain?.cancel()
        feedbackChain = nil
        feedbackLoadTask?.cancel()
        feedbackLoadTask = nil
        feedbackIdentity = nil
        deliveryOutbox?.deactivate()
        stopFeed()
        started = false
    }

    func setScrobblingEnabled(_ enabled: Bool) {
        guard enabled != state.scrobblingEnabled else { return }
        state.scrobblingEnabled = enabled
        persistCurrentSettings()
        if enabled, store != nil, started, state.pausedUntil == nil {
            startFeed()
        } else {
            stopFeed()
        }
    }

    /// Moves the engine's threshold floor. The current session picks it up on
    /// its next sample; a track is never pre-filtered by its duration.
    func setMinimumDuration(_ seconds: TimeInterval) {
        let range = CaptureSettings.minimumDurationRange
        let clamped = min(max(seconds, range.lowerBound), range.upperBound)
        guard clamped != state.minimumDuration else { return }
        state.minimumDuration = clamped
        engine.setMinimumThreshold(clamped)
        persistCurrentSettings()
    }
}
