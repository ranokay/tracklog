import Foundation

/// One line the composition root may log. It carries no credential by
/// construction, and none of its descriptions include a service message.
public enum DeliveryEvent: Equatable, Sendable, CustomStringConvertible {
    case delivered(kind: ServiceKind, count: Int)
    case failed(kind: ServiceKind, reason: String)
    case abandoned(kind: ServiceKind, reason: String)

    public var description: String {
        switch self {
        case let .delivered(kind, count):
            "Delivered \(count) to \(kind.displayName)"
        case let .failed(kind, reason):
            "Delivery to \(kind.displayName) failed: \(reason)"
        case let .abandoned(kind, reason):
            "Abandoned a delivery to \(kind.displayName): \(reason)"
        }
    }
}
