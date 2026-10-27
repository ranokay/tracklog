import Foundation

// MARK: - The listen in flight

public extension CaptureRuntime {
    /// Suppresses the current session's scrobble and history row until the
    /// track changes, restarts or is undone. Ends by itself once the threshold
    /// has fired, which the status exposes as `canCancel`.
    @discardableResult
    func cancelCurrentListen() -> Bool {
        let cancelled = engine.cancelCurrentSession()
        if cancelled {
            state.status = engine.status
        }
        return cancelled
    }

    @discardableResult
    func undoCancelCurrentListen() -> Bool {
        let undone = engine.undoCancelCurrentSession()
        if undone {
            state.status = engine.status
        }
        return undone
    }

    /// The raw fields of the current listen, ready to pre-fill a new edit.
    /// Nil when no track is armed.
    func editMatchForCurrentListen() -> SimpleEditRule.Match? {
        guard let raw = engine.currentRawTrack else { return nil }
        return .prefilled(from: ListenMetadata(raw))
    }
}

extension CaptureRuntime {
    /// Pushes the metadata the current rules would submit into the session in
    /// flight. Called when the rules change, so an edit saved mid-track
    /// revises the eventual scrobble without touching played time.
    func reviseCurrentSubmission() {
        guard let raw = engine.currentRawTrack,
              let processed = MetadataPipeline.process(
                  raw,
                  edits: state.simpleEdits,
                  blocks: state.blocks,
              )
        else { return }
        engine.reviseCurrentTrack(raw.replacingMetadata(processed))
    }
}
