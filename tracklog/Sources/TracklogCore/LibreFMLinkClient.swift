import Foundation

/// The browser-link half of the Libre.fm adapter, bound to the one root the
/// listener entered. It names a refused client key inline and leaves every
/// other protocol error untouched, so the page keeps polling an unapproved
/// token.
public struct LibreFMLinkClient: LastFMLinkClient {
    private let client: LastFMClient

    init(client: LastFMClient) {
        self.client = client
    }

    public func requestToken() async throws -> LastFMLinkChallenge {
        try await translate { try await client.requestToken() }
    }

    public func session(token: String) async throws -> LastFMSession {
        try await translate { try await client.session(token: token) }
    }

    private func translate<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch {
            throw LibreFMAdapter.linkFailure(for: error)
        }
    }
}
