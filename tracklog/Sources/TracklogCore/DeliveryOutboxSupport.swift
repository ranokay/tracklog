import Foundation

/// The result of applying one batch's per-item outcomes.
struct DeliveryApplyOutcome {
    /// False when a daily limit says the next batch would be refused too.
    let continueDraining: Bool
    /// False when a local row could not record its outcome.
    let persisted: Bool
}

/// One feedback action waiting for its connection's worker. The continuation
/// is resumed exactly once, whether the action runs, is cancelled, or the
/// connection or outbox stops first.
@MainActor
final class PendingFeedback {
    let action: FeedbackAction
    let track: Track
    let scope: FeedbackScope
    private var continuation: CheckedContinuation<Connection?, Never>?
    private var resumed = false
    private(set) var isCancelled = false

    init(action: FeedbackAction, track: Track, scope: FeedbackScope) {
        self.action = action
        self.track = track
        self.scope = scope
    }

    func attach(_ continuation: CheckedContinuation<Connection?, Never>) {
        self.continuation = continuation
    }

    /// A cancelled action never reports a success, even if its request was
    /// already in flight when the cancellation landed.
    func cancel() {
        isCancelled = true
        resume(nil)
    }

    func resume(_ connection: Connection?) {
        guard !resumed, let continuation else { return }
        resumed = true
        self.continuation = nil
        continuation.resume(returning: connection)
    }
}

/// One connection's in-memory work. Never holds a credential.
@MainActor
final class ConnectionWorker {
    var task: Task<Void, Never>?
    var drainRequested = false
    var runAgain = false
    var nowPlaying: Track?
    var feedback: [PendingFeedback] = []

    func stop() {
        task?.cancel()
        nowPlaying = nil
        runAgain = false
        drainRequested = false
        for pending in feedback {
            pending.resume(nil)
        }
        feedback.removeAll()
    }
}

public extension DeliveryOutbox {
    /// The recording reference the last now playing returned, when one did.
    func nowPlayingReference(forConnection id: Int64) -> String? {
        nowPlayingReferences[id]
    }
}
