import Foundation
import Network

/// Reports the first usable network path and every later recovery, so a held
/// delivery can drain without waiting for its retry clock.
@MainActor
final class NetworkReachability {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "app.tracklog.network-reachability")
    private let onAvailable: @Sendable @MainActor () -> Void
    private var isStarted = false

    init(onAvailable: @escaping @Sendable @MainActor () -> Void) {
        self.onAvailable = onAvailable
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        let notify = onAvailable
        monitor.pathUpdateHandler = { path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in
                notify()
            }
        }
        monitor.start(queue: queue)
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        monitor.pathUpdateHandler = nil
        monitor.cancel()
    }
}
