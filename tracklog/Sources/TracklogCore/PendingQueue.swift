import Foundation

/// One listen waiting for one connection, with everything the pending list
/// shows.
public struct PendingDeliveryItem: Identifiable, Equatable, Sendable {
    public let delivery: Delivery
    public let listen: Listen
    public let connection: Connection

    public var id: Int64 {
        delivery.id
    }
}

/// One connection's pending deliveries, oldest listen first.
public struct PendingDeliveryGroup: Identifiable, Equatable, Sendable {
    public let connection: Connection
    public let items: [PendingDeliveryItem]

    public var id: Int64 {
        connection.id ?? -1
    }
}

/// The whole pending list, grouped in connection order. It is built from the
/// store's pending rows so the History banner and the pending list read the
/// same snapshot.
public struct PendingQueue: Equatable, Sendable {
    public let groups: [PendingDeliveryGroup]

    public init(groups: [PendingDeliveryGroup] = []) {
        self.groups = groups
    }

    public init(pending: [QueuedDelivery], connections: [Connection]) {
        let byID = Dictionary(
            uniqueKeysWithValues: connections.compactMap { connection in
                connection.id.map { ($0, connection) }
            },
        )
        var grouped: [Int64: [PendingDeliveryItem]] = [:]
        for queued in pending {
            guard let connectionID = queued.delivery.connectionID,
                  let connection = byID[connectionID]
            else { continue }
            grouped[connectionID, default: []].append(
                PendingDeliveryItem(
                    delivery: queued.delivery,
                    listen: queued.listen,
                    connection: connection,
                ),
            )
        }
        groups = connections.compactMap { connection in
            guard let id = connection.id, let items = grouped[id], !items.isEmpty else { return nil }
            return PendingDeliveryGroup(
                connection: connection,
                items: items.sorted {
                    if $0.listen.startedAt != $1.listen.startedAt {
                        return $0.listen.startedAt < $1.listen.startedAt
                    }
                    return $0.delivery.id < $1.delivery.id
                },
            )
        }
    }

    public var count: Int {
        groups.reduce(0) { $0 + $1.items.count }
    }

    public var isEmpty: Bool {
        groups.isEmpty
    }

    /// Connections that are actively retrying after a rate-limit response. A
    /// paused or needs-sign-in connection is not retrying, so it does not
    /// count.
    public var rateLimitedConnections: [Connection] {
        groups.compactMap { group in
            guard group.connection.isEnabled, group.connection.authState == .signedIn,
                  group.items.contains(where: \.delivery.isRateLimited)
            else { return nil }
            return group.connection
        }
    }
}

/// The one banner pinned above the History feed. The highest-priority problem
/// owns the slot.
public enum HistoryBanner: Equatable, Sendable {
    case mediaFeedUnavailable
    case needsSignIn([Connection])
    case rateLimited([Connection])
    case pending(PendingQueue)

    public static func resolve(
        feedAvailable: Bool,
        connections: [Connection],
        pending: PendingQueue,
    ) -> HistoryBanner? {
        if !feedAvailable {
            return .mediaFeedUnavailable
        }
        let needsSignIn = connections.filter { $0.isEnabled && $0.authState == .needsSignIn }
        if !needsSignIn.isEmpty {
            return .needsSignIn(needsSignIn)
        }
        let rateLimited = pending.rateLimitedConnections
        if !rateLimited.isEmpty {
            return .rateLimited(rateLimited)
        }
        if !pending.isEmpty {
            return .pending(pending)
        }
        return nil
    }
}
