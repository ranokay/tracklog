import Foundation

/// The result of applying one batch's per-item outcomes.
struct DeliveryApplyOutcome {
    /// False when a daily limit says the next batch would be refused too.
    let continueDraining: Bool
    /// False when a local row could not record its outcome.
    let persisted: Bool
}

/// One connection's in-memory work. Never holds a credential.
@MainActor
final class ConnectionWorker {
    var task: Task<Void, Never>?
    var drainRequested = false
    var runAgain = false
    var nowPlaying: Track?

    func stop() {
        task?.cancel()
        nowPlaying = nil
        runAgain = false
        drainRequested = false
    }
}

public extension DeliveryOutbox {
    /// The recording reference the last now playing returned, when one did.
    func nowPlayingReference(forConnection id: Int64) -> String? {
        nowPlayingReferences[id]
    }
}
