import Foundation

/// Serializes operations that span several awaits. A load must never observe
/// or repair a link that has saved its row but not its credential or cursor.
@MainActor
final class ConnectionOperationGate {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var hasHolder: Bool {
        isLocked
    }

    func acquire() async {
        guard isLocked else {
            isLocked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            isLocked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
