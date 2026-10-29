import Foundation

/// The protocol's failures before they are mapped onto ``ServiceFailure``.
/// The link flow needs to distinguish code 14 (not authorized yet) from a
/// rejected session, so the raw service codes stay available here.
public enum LastFMError: Error, Equatable, Sendable {
    case missingAppCredentials
    case missingSessionKey
    case transport
    case http(statusCode: Int, retryAfter: TimeInterval?)
    case service(code: Int, message: String?)
    case malformedResponse

    /// The one failure taxonomy the rest of the engine speaks.
    public var serviceFailure: ServiceFailure {
        switch self {
        case .missingAppCredentials:
            .appCredentialAuth(.missing)
        case .missingSessionKey:
            .auth
        case .transport:
            .retryable
        case let .http(statusCode, retryAfter):
            switch statusCode {
            case 429: .rateLimited(retryAfter: retryAfter)
            case 401, 403: .auth
            case 500 ..< 600: .retryable
            case 400 ..< 500: .rejected(nil)
            default: .retryable
            }
        case let .service(code, message):
            switch code {
            case 4, 9, 14, 15: .auth
            case 10: .appCredentialAuth(.invalidKey)
            case 13: .appCredentialAuth(.invalidSignature)
            case 26: .appCredentialAuth(.suspendedKey)
            case 8, 11, 16: .retryable
            case 29: .rateLimited(retryAfter: nil)
            case 6, 7: .rejected(message)
            default: .rejected(message)
            }
        case .malformedResponse:
            .retryable
        }
    }
}
