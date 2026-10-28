import Foundation

/// The one state a history row's delivery glyph can show.
public enum DeliveryAggregate: Equatable, Sendable {
    /// Every target accepted the listen, and there is at least one.
    case delivered
    /// At least one target is still waiting or retrying.
    case pending
    /// At least one target will never take the listen, and none is pending.
    case notDelivered
    /// The listen had no delivery targets at capture time.
    case none

    public init(_ deliveries: [Delivery]) {
        if deliveries.contains(where: \.state.isPending) {
            self = .pending
        } else if deliveries.contains(where: { $0.state == .abandoned }) {
            self = .notDelivered
        } else if !deliveries.isEmpty {
            self = .delivered
        } else {
            self = .none
        }
    }
}

/// A listen's deliveries, summarised for its one history row.
public struct DeliverySummary: Equatable, Sendable {
    public let deliveries: [Delivery]

    public init(_ deliveries: [Delivery]) {
        self.deliveries = deliveries
    }

    public var aggregate: DeliveryAggregate {
        DeliveryAggregate(deliveries)
    }

    /// "delivered to Last.fm", "waiting for Last.fm", "not delivered to
    /// Libre.fm", or the three joined with semicolons when the row is mixed.
    /// Every service is named.
    public func accessibilityValue(connections: [Connection]) -> String {
        guard !deliveries.isEmpty else { return "No delivery targets" }
        let delivered = names(connections: connections) { $0 == .delivered }
        let pending = names(connections: connections) { $0.isPending }
        let abandoned = names(connections: connections) { $0 == .abandoned }

        var parts: [String] = []
        if !delivered.isEmpty {
            parts.append("delivered to \(joined(delivered))")
        }
        if !pending.isEmpty {
            parts.append("waiting for \(joined(pending))")
        }
        if !abandoned.isEmpty {
            parts.append("not delivered to \(joined(abandoned))")
        }
        return parts.joined(separator: "; ")
    }

    /// One service name per matching delivery, in connection order and
    /// without repeats.
    private func names(
        connections: [Connection],
        where matches: (DeliveryState) -> Bool,
    ) -> [String] {
        var names: [String] = []
        for delivery in deliveries where matches(delivery.state) {
            let name = connections.first { $0.id == delivery.connectionID }?.kind.displayName
                ?? "an unknown service"
            if !names.contains(name) {
                names.append(name)
            }
        }
        return names
    }

    private func joined(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
    }
}
