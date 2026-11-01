import Foundation

/// One successful service top-entity response: the ranked rows and the span
/// the service says it computed.
public struct ChartServicePage: Equatable, Sendable {
    public let items: [ChartItem]
    public let returnedRange: ChartReturnedRange?

    public init(items: [ChartItem], returnedRange: ChartReturnedRange? = nil) {
        self.items = items
        self.returnedRange = returnedRange
    }
}

/// A 204 is not an empty chart: the service has not finished calculating it.
public enum ChartServiceError: Error, Equatable, Sendable {
    case notReady
}

/// The service half of the stats boundary. Last.fm and ListenBrainz implement
/// it; Libre.fm does not, which is why the read model can only offer its
/// named local fallback.
public protocol ChartServiceReading: Sendable {
    var kind: ServiceKind { get }
    func top(
        _ type: ChartType,
        period: ChartPeriod,
        connection: Connection,
        credential: String,
        limit: Int,
    ) async throws -> ChartServicePage
    func allTimeAccountTotal(
        connection: Connection,
        credential: String,
    ) async throws -> Int
}

enum ChartIdentity {
    /// A provider MBID is preferred. Without one, a source-scoped fallback key
    /// still names the row; it is never fed through local metadata merging.
    static func serviceKey(
        providerID: String?,
        type: ChartType,
        title: String,
        subtitle: String,
    ) -> String {
        if let providerID {
            let trimmed = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return "mbid:\(trimmed)"
            }
        }
        return "fallback:\(type.rawValue):\(Identity.joined([title, subtitle]))"
    }

    static func nextRank(_ index: Int) -> Int {
        index + 1
    }
}

/// The host and fixtures both speak the one HTTP transport. A route answers
/// by an exact method/URL shape so a charts test can script both services.
enum ChartServiceHTTP {
    static func data(
        _ transport: any HTTPTransport,
        request: HTTPRequest,
    ) async throws -> HTTPResponse {
        do {
            return try await transport.send(request)
        } catch {
            throw ServiceFailure.retryable
        }
    }

    static func retryAfter(from response: HTTPResponse) -> TimeInterval? {
        for name in ["Retry-After", "X-RateLimit-Reset-In"] {
            guard let value = response.header(name)?.trimmingCharacters(in: .whitespaces),
                  let seconds = TimeInterval(value)
            else { continue }
            return seconds
        }
        return nil
    }
}
