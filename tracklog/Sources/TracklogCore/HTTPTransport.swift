import Foundation

public enum HTTPMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
}

/// One request as it crosses the transport port. Adapters build it; the
/// production transport sends it; recorded fixtures answer it in tests.
public struct HTTPRequest: Equatable, Sendable {
    public var method: HTTPMethod
    public var url: URL
    public var headers: [String: String]
    public var body: Data?

    public init(
        method: HTTPMethod,
        url: URL,
        headers: [String: String] = [:],
        body: Data? = nil,
    ) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

public struct HTTPResponse: Equatable, Sendable {
    public var statusCode: Int
    public var headers: [String: String]
    public var body: Data

    public init(statusCode: Int, headers: [String: String] = [:], body: Data) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    /// One response header, matched without regard to case.
    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

/// The one redirect rule every Tracklog request keeps: a redirect may change
/// the path, never the security of the connection. A 307 or 308 resends the
/// request body, which can carry a session key, so a hop to cleartext HTTP is
/// refused rather than followed.
public enum HTTPRedirectPolicy {
    /// Whether a redirect to `url` may proceed. Only HTTPS destinations do.
    public static func allows(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
    }
}

/// A transport-level refusal for a response body that would exceed the
/// caller's limit before it is materialized.
public enum HTTPTransportError: Error, Equatable, Sendable {
    case bodyTooLarge(limit: Int)
}

/// The one request/response seam. No client opens its own session: production
/// is URLSession, tests are recorded fixtures.
public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse

    /// Sends a request whose body is refused once it passes `limit`. The
    /// default buffers through `send`; the production transport streams and
    /// cancels the task at the limit, so a hostile response cannot occupy
    /// more memory than the caller allows.
    func send(_ request: HTTPRequest, bodyLimit: Int) async throws -> HTTPResponse
}

public extension HTTPTransport {
    func send(_ request: HTTPRequest, bodyLimit: Int) async throws -> HTTPResponse {
        let response = try await send(request)
        guard response.body.count <= bodyLimit else {
            throw HTTPTransportError.bodyTooLarge(limit: bodyLimit)
        }
        return response
    }
}

/// The identifiers every service request carries.
public enum TracklogHTTP {
    /// Keep the version in step with `droplet.json`.
    public static let version = "1.0.0"
    /// Named on every request so services can identify and contact the app.
    public static let userAgent = "Tracklog/\(version) (+https://github.com/ranokay/tracklog)"
}
