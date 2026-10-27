import Foundation

// MARK: - The listen in flight

public extension CaptureRuntime {
    /// Suppresses the current session's scrobble and history row until the
    /// track changes, restarts or is undone. Ends by itself once the threshold
    /// has fired, which the status exposes as `canCancel`.
    @discardableResult
    func cancelCurrentListen() -> Bool {
        publish(engine.cancelCurrentSession())
    }

    @discardableResult
    func undoCancelCurrentListen() -> Bool {
        publish(engine.undoCancelCurrentSession())
    }

    /// The current listen's fields as the rules will see them, ready to
    /// pre-fill a new edit. Sentinel cleanup runs first, so a placeholder the
    /// pipeline blanks is not offered as a match that can never fire.
    func editMatchForCurrentListen() -> SimpleEditRule.Match? {
        guard let raw = engine.currentRawTrack else { return nil }
        return .prefilled(from: MetadataPipeline.sentinelCleanup(ListenMetadata(raw)))
    }

    private func publish(_ applied: Bool) -> Bool {
        if applied {
            state.status = engine.status
        }
        return applied
    }
}
