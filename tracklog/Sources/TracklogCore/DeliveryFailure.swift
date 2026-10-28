import Foundation

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
