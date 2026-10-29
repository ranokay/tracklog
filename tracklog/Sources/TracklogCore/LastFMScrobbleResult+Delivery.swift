import Foundation

public extension LastFMScrobbleResult {
    /// The outbox's vocabulary. Both dialects share the ignored codes, so the
    /// mapping is written once and the service name only names the reason.
    func deliveryResult(serviceName: String) -> DeliveryResult {
        switch self {
        case .accepted:
            return .delivered(reference: nil)
        case let .ignored(code):
            // Code 5 is the service's daily limit, which a retry cannot fix
            // for this batch but a later one can.
            guard code != 5 else { return .rateLimited(retryAfter: nil) }
            return .rejected(reason: "\(serviceName) ignored this scrobble (code \(code)).")
        }
    }
}
