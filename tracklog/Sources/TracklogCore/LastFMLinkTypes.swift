import Foundation

/// One request-token exchange. The authorization page carries the token the
/// listener approves in their browser.
public struct LastFMLinkChallenge: Equatable, Sendable {
    public let token: String
    public let authorizationURL: URL

    public init(token: String, authorizationURL: URL) {
        self.token = token
        self.authorizationURL = authorizationURL
    }
}

/// A listener's Last.fm session. The key is the credential that belongs in the
/// Keychain; it is never logged or persisted anywhere else.
public struct LastFMSession: Equatable, Sendable {
    public let name: String
    public let key: String

    public init(name: String, key: String) {
        self.name = name
        self.key = key
    }
}

/// What a Last.fm-protocol service said about one item in a scrobble batch.
public enum LastFMScrobbleResult: Equatable, Sendable {
    case accepted
    case ignored(code: Int)
}

/// The browser-link half of the Last.fm client, kept narrow so the page model
/// can be tested without the delivery surface.
public protocol LastFMLinkClient: Sendable {
    func requestToken() async throws -> LastFMLinkChallenge
    func session(token: String) async throws -> LastFMSession
}
