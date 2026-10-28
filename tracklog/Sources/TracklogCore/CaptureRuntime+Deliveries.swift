import Foundation

// MARK: - Delivery state for the surfaces

extension CaptureRuntime {
    /// Reads the pending list and the deliveries for the loaded history page.
    /// A read failure keeps the previous snapshot rather than blanking the
    /// History rows.
    public func reloadDeliveryState() async {
        guard let deliveryStore else {
            state.pendingQueue = PendingQueue()
            state.deliveriesByListen = [:]
            return
        }
        deliveryReloadGeneration += 1
        let generation = deliveryReloadGeneration

        let pending: [QueuedDelivery]
        do {
            pending = try await deliveryStore.pendingDeliveries()
        } catch {
            return
        }
        guard isCurrentDeliveryReload(generation) else { return }
        state.pendingQueue = PendingQueue(pending: pending, connections: state.connections)

        let listenIDs = state.listens.compactMap(\.id)
        guard !listenIDs.isEmpty else {
            guard isCurrentDeliveryReload(generation) else { return }
            state.deliveriesByListen = [:]
            return
        }
        do {
            let deliveries = try await deliveryStore.deliveries(forListenIDs: listenIDs)
            guard isCurrentDeliveryReload(generation) else { return }
            state.deliveriesByListen = Dictionary(grouping: deliveries, by: \.listenID)
        } catch {
            return
        }
    }

    private func isCurrentDeliveryReload(_ generation: Int) -> Bool {
        generation == deliveryReloadGeneration && !Task.isCancelled
    }

    /// Abandons one delivery and leaves its listen in local history. The
    /// pending list and the row's glyph are refreshed from the store.
    public func deleteDelivery(_ delivery: Delivery) async {
        guard let deliveryStore else { return }
        do {
            try await deliveryStore.abandon(
                delivery.id,
                attempts: delivery.attempts,
                lastAttemptAt: delivery.lastAttemptAt,
                reason: Self.deletedDeliveryReason,
            )
        } catch {
            state.failure = .storage(error: error)
        }
        await reloadDeliveryState()
    }

    /// Coalesces the outbox's end-of-drain changes and the capture path's
    /// writes into one delivery read for the surfaces.
    func scheduleDeliveryRefresh() {
        deliveryRefreshTask?.cancel()
        deliveryRefreshTask = Task { [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            await reloadDeliveryState()
        }
    }

    static let deletedDeliveryReason = "Deleted from the pending list."
}
