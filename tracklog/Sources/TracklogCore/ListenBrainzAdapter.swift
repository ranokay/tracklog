import Foundation

/// ListenBrainz's token link: one GET with the user token, the username from
/// the answer.
public struct ListenBrainzAdapter: ServiceAdapter {
    public let kind = ServiceKind.listenBrainz
    public let capabilities = ServiceCapabilities(
        supportsNowPlaying: true,
        maximumBatchSize: 1,
        supportsLove: true,
        supportsHate: true,
        supportsDelete: false,
        signsRequests: false,
    )

    private let endpoint: ServiceEndpoint
    private let transport: any HTTPTransport
    private let userAgent: String

    public init(
        endpoint: ServiceEndpoint = .listenBrainz,
        transport: any HTTPTransport,
        userAgent: String = TracklogHTTP.userAgent,
    ) {
        self.endpoint = endpoint
        self.transport = transport
        self.userAgent = userAgent
    }

    public func validate(_ credential: String) async throws -> ServiceIdentity {
        let token = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw ServiceFailure.rejected("Enter a user token.") }
        guard let url = URL(string: "\(endpoint.description)/1/validate-token") else {
            throw ServiceFailure.rejected(nil)
        }

        let request = HTTPRequest(
            method: .get,
            url: url,
            headers: [
                "Authorization": "Token \(token)",
                "User-Agent": userAgent,
                "Accept": "application/json",
            ],
        )

        let response: HTTPResponse
        do {
            response = try await transport.send(request)
        } catch {
            throw ServiceFailure.retryable
        }

        switch response.statusCode {
        case 200 ..< 300:
            return try identity(from: response)
        case 401, 403:
            throw ServiceFailure.auth
        case 429:
            throw ServiceFailure.rateLimited(retryAfter: retryAfter(from: response))
        case 400 ..< 500:
            throw ServiceFailure.rejected(message(from: response))
        default:
            throw ServiceFailure.retryable
        }
    }

    private func identity(from response: HTTPResponse) throws -> ServiceIdentity {
        guard let body = try? JSONDecoder().decode(TokenResponse.self, from: response.body) else {
            throw ServiceFailure.retryable
        }
        if body.valid == false {
            throw ServiceFailure.auth
        }
        let name = body.userName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else { throw ServiceFailure.retryable }
        return ServiceIdentity(name: name)
    }

    private func message(from response: HTTPResponse) -> String? {
        let body = try? JSONDecoder().decode(TokenResponse.self, from: response.body)
        let message = body?.message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return message.isEmpty ? nil : message
    }

    private func retryAfter(from response: HTTPResponse) -> TimeInterval? {
        for name in ["X-RateLimit-Reset-In", "Retry-After"] {
            guard let value = response.header(name)?.trimmingCharacters(in: .whitespaces),
                  let seconds = TimeInterval(value)
            else { continue }
            return seconds
        }
        return nil
    }
}

private struct TokenResponse: Decodable {
    let valid: Bool?
    let userName: String?
    let message: String?

    enum CodingKeys: String, CodingKey {
        case valid
        case userName = "user_name"
        case message
    }
}
