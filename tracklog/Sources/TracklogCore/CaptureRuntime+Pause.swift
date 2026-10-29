import Foundation

// MARK: - Pause and capture switches

public extension CaptureRuntime {
    /// An expired pause is stale, not a resume: activation clears it and starts
    /// capture without treating it as a user action.
    internal func clearExpiredPauseOnActivation() {
        guard let until = state.pausedUntil, until <= clock.now else { return }
        clearPauseState()
    }

    /// Pauses capture and now playing until `date`. The in-flight,
    /// pre-threshold session is discarded, not stored. A pause already in the
    /// past is a no-op.
    func pause(until date: Date) {
        pause(until: date, announcement: .until(date))
    }

    /// Pauses for a duration from the runtime's clock.
    func pause(for duration: TimeInterval) {
        pause(
            until: clock.now.addingTimeInterval(duration),
            announcement: .duration(duration),
        )
    }

    private func pause(until date: Date, announcement: PauseAnnouncement) {
        guard date > clock.now else { return }
        state.pausedUntil = date
        persistCurrentSettings()
        stopFeed()
        schedulePauseExpiry()
        showHUD(.paused(announcement))
    }

    /// Gates the now-playing send only. Capture and local history keep running.
    func setNowPlayingEnabled(_ enabled: Bool) {
        guard enabled != state.nowPlayingEnabled else { return }
        state.nowPlayingEnabled = enabled
        persistCurrentSettings()
    }

    /// The user's explicit resume. An expired pause uses the private path so a
    /// future confirmation HUD can tell the two apart.
    func resume() {
        guard state.pausedUntil != nil else { return }
        pauseTask?.cancel()
        pauseTask = nil
        endPause()
        showHUD(.resumed)
    }

    /// The composition schedules the feed to restart when the pause expires;
    /// the user does not have to be present.
    internal func schedulePauseExpiry() {
        pauseTask?.cancel()
        pauseTask = nil
        guard let until = state.pausedUntil, until > clock.now else { return }

        pauseTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await clock.sleep(until: until)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            clearExpiredPause()
        }
    }

    private func clearExpiredPause() {
        guard state.pausedUntil != nil else { return }
        pauseTask = nil
        endPause()
    }

    /// Ends a pause and lets capture continue when every other gate is open.
    /// Activation uses the narrower `clearPauseState` because it starts the
    /// feed itself once history and the allowlist are loaded.
    private func endPause() {
        clearPauseState()
        if started, state.scrobblingEnabled, store != nil {
            startFeed()
        }
    }

    private func clearPauseState() {
        state.pausedUntil = nil
        persistCurrentSettings()
    }

    /// Writes the whole switch set, so a surface never has to know which key
    /// changed.
    internal func persistCurrentSettings() {
        persistSettings?(CaptureSettings(
            scrobblingEnabled: state.scrobblingEnabled,
            nowPlayingEnabled: state.nowPlayingEnabled,
            pausedUntil: state.pausedUntil,
            minimumDuration: state.minimumDuration,
        ))
    }
}
