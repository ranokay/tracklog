import Foundation

/// Wakes at the earliest pending delivery attempt while the outbox is active.
/// There is no background scheduler: cancelling this task is what deactivation
/// does, and the durable rows wait for the next activation.
@MainActor
final class DeliveryScheduler {
    private let store: any DeliveryStore
    private let clock: any Clock
    private let eligibleConnectionIDs: @MainActor () -> [Int64]
    private let drain: @MainActor ([Int64]) -> Void
    private var task: Task<Void, Never>?

    init(
        store: any DeliveryStore,
        clock: any Clock,
        eligibleConnectionIDs: @escaping @MainActor () -> [Int64],
        drain: @escaping @MainActor ([Int64]) -> Void,
    ) {
        self.store = store
        self.clock = clock
        self.eligibleConnectionIDs = eligibleConnectionIDs
        self.drain = drain
    }

    func reschedule() {
        task?.cancel()
        task = Task { @MainActor [weak self] in
            await self?.waitForNextAttempt()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    private func waitForNextAttempt() async {
        let eligible = eligibleConnectionIDs()
        guard !eligible.isEmpty else { return }
        let next = try? await store.earliestNextAttempt(for: eligible)
        guard let next else { return }

        // A one-second floor keeps a row that cannot be read from spinning the
        // scheduler; every real retry delay is longer.
        let wakeAt = max(next, clock.now.addingTimeInterval(1))
        try? await clock.sleep(until: wakeAt)
        guard !Task.isCancelled else { return }
        drain(eligible)
    }
}
