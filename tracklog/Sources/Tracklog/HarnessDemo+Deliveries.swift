import Foundation
import TracklogCore

extension HarnessDemoStore {
    // MARK: Deliveries

    func dueDeliveries(
        for connectionID: Int64,
        limit: Int,
        at date: Date,
    ) async throws -> [QueuedDelivery] {
        guard limit > 0 else { return [] }
        return deliveryRows
            .filter {
                $0.connectionID == connectionID
                    && $0.state.isPending
                    && ($0.nextAttemptAt ?? .distantPast) <= date
            }
            .sorted { left, right in
                let leftStart = listens.first { $0.id == left.listenID }?.startedAt ?? .distantPast
                let rightStart = listens.first { $0.id == right.listenID }?.startedAt ?? .distantPast
                return leftStart == rightStart ? left.id < right.id : leftStart < rightStart
            }
            .prefix(limit)
            .compactMap { delivery in
                listens.first { $0.id == delivery.listenID }.map {
                    QueuedDelivery(delivery: delivery, listen: $0)
                }
            }
    }

    func deliveries(for listenID: Int64) async throws -> [Delivery] {
        deliveryRows.filter { $0.listenID == listenID }
    }

    func deliveries(forListenIDs listenIDs: [Int64]) async throws -> [Delivery] {
        deliveryRows.filter { listenIDs.contains($0.listenID) }
    }

    func pendingDeliveries() async throws -> [QueuedDelivery] {
        deliveryRows
            .filter(\.state.isPending)
            .sorted { left, right in
                let leftStart = listens.first { $0.id == left.listenID }?.startedAt ?? .distantPast
                let rightStart = listens.first { $0.id == right.listenID }?.startedAt ?? .distantPast
                return leftStart == rightStart ? left.id < right.id : leftStart < rightStart
            }
            .compactMap { delivery in
                listens.first { $0.id == delivery.listenID }.map {
                    QueuedDelivery(delivery: delivery, listen: $0)
                }
            }
    }

    func markDelivered(_ deliveryID: Int64, at date: Date, reference: String?) async throws {
        updateDelivery(deliveryID) { delivery in
            Delivery(
                id: delivery.id,
                listenID: delivery.listenID,
                connectionID: delivery.connectionID,
                state: .delivered,
                attempts: delivery.attempts,
                lastAttemptAt: date,
                nextAttemptAt: nil,
                lastError: nil,
                abandonedReason: nil,
                deliveredAt: date,
                serviceReference: reference,
            )
        }
    }

    func markFailed(
        _ deliveryID: Int64,
        attempts: Int,
        at date: Date,
        nextAttemptAt: Date,
        error: String,
    ) async throws {
        updateDelivery(deliveryID) { delivery in
            Delivery(
                id: delivery.id,
                listenID: delivery.listenID,
                connectionID: delivery.connectionID,
                state: .retrying,
                attempts: attempts,
                lastAttemptAt: date,
                nextAttemptAt: nextAttemptAt,
                lastError: error,
                abandonedReason: nil,
                deliveredAt: nil,
                serviceReference: delivery.serviceReference,
            )
        }
    }

    func abandon(_ deliveryID: Int64, attempts: Int, at date: Date, reason: String) async throws {
        updateDelivery(deliveryID) { delivery in
            Delivery(
                id: delivery.id,
                listenID: delivery.listenID,
                connectionID: delivery.connectionID,
                state: .abandoned,
                attempts: attempts,
                lastAttemptAt: date,
                nextAttemptAt: nil,
                lastError: reason,
                abandonedReason: reason,
                deliveredAt: nil,
                serviceReference: delivery.serviceReference,
            )
        }
    }

    func markDue(for connectionID: Int64, at date: Date) async throws {
        for delivery in deliveryRows where delivery.connectionID == connectionID && delivery.state.isPending {
            updateDelivery(delivery.id) { current in
                Delivery(
                    id: current.id,
                    listenID: current.listenID,
                    connectionID: current.connectionID,
                    state: current.state,
                    attempts: current.attempts,
                    lastAttemptAt: current.lastAttemptAt,
                    nextAttemptAt: date,
                    lastError: current.lastError,
                    abandonedReason: current.abandonedReason,
                    deliveredAt: current.deliveredAt,
                    serviceReference: current.serviceReference,
                )
            }
        }
    }

    func earliestNextAttempt(for connectionIDs: [Int64]) async throws -> Date? {
        deliveryRows
            .filter { connectionIDs.contains($0.connectionID) && $0.state.isPending }
            .compactMap(\.nextAttemptAt)
            .min()
    }

    private func updateDelivery(_ id: Int64, _ update: (Delivery) -> Delivery) {
        guard let index = deliveryRows.firstIndex(where: { $0.id == id }) else { return }
        deliveryRows[index] = update(deliveryRows[index])
    }
}
