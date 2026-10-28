import TracklogCore

extension TracklogDroplet {
    // MARK: - Deliveries

    func retryDeliveries(forConnection id: Int64) {
        runtime?.retryDeliveries(forConnection: id)
    }

    func retryDeliveries(forConnections connections: [Connection]) {
        for connection in connections {
            guard let id = connection.id else { continue }
            runtime?.retryDeliveries(forConnection: id)
        }
    }

    func deleteDelivery(_ delivery: Delivery) {
        Task { await runtime?.deleteDelivery(delivery) }
    }
}
