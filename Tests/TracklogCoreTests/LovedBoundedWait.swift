import Foundation

/// A bounded wait for an unstructured task. Whichever finishes first — the
/// task or the deadline — resumes the waiter; a stuck task cannot keep the
/// test blocked, and the nil result records the failure in the caller.
actor LovedCompletion<Value: Sendable> {
    private var result: Value?
    private var didTimeOut = false
    private var waiter: CheckedContinuation<Value?, Never>?

    func finish(_ value: Value) {
        guard result == nil, !didTimeOut else { return }
        result = value
        waiter?.resume(returning: value)
        waiter = nil
    }

    func timeOut() {
        guard result == nil, !didTimeOut else { return }
        didTimeOut = true
        waiter?.resume(returning: nil)
        waiter = nil
    }

    func wait() async -> Value? {
        await withCheckedContinuation { continuation in
            if let result {
                continuation.resume(returning: result)
            } else if didTimeOut {
                continuation.resume(returning: nil)
            } else {
                waiter = continuation
            }
        }
    }
}

@MainActor
func lovedAwait<Value: Sendable>(
    _ task: Task<Value, Never>,
    timeout: Duration = .seconds(5),
) async -> Value? {
    let completion = LovedCompletion<Value>()
    Task {
        let value = await task.value
        await completion.finish(value)
    }
    Task {
        try? await Task.sleep(for: timeout)
        await completion.timeOut()
    }
    return await completion.wait()
}
