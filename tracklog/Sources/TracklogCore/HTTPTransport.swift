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

/// The one request/response seam. No client opens its own session: production
/// is URLSession, tests are recorded fixtures.
public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

/// The identifiers every service request carries.
public enum TracklogHTTP {
    /// Keep the version in step with `droplet.json`.
    public static let version = "1.0.0"
    /// Named on every request so services can identify and contact the app.
    public static let userAgent = "Tracklog/\(version) (+https://github.com/ranokay/tracklog)"
}
