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

/// The failure text stored on a delivery row. It never includes a credential;
/// the adapters carry none into their messages.
enum DeliveryFailure {
    static func from(_ error: any Error) -> ServiceFailure {
        (error as? ServiceFailure) ?? .retryable
    }

    static func message(for failure: ServiceFailure) -> String {
        switch failure {
        case .auth:
            "The service did not accept the credential."
        case .rateLimited:
            "The service is rate limiting requests."
        case .retryable:
            "The service could not be reached."
        case let .rejected(message):
            normalized(message) ?? "The service rejected this listen."
        }
    }

    static func normalized(_ message: String?) -> String? {
        let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
