import Foundation

/// Checks a candidate application pair before it replaces the pair in use.
/// The command is `auth.getToken`: it needs no user session and Last.fm
/// answers 10 for a bad key and 13 for a bad signature.
public protocol LastFMAppCredentialValidating: Sendable {
    func validateAppCredentials(_ credentials: LastFMAppCredentials) async throws
}

/// Last.fm's delivery adapter. The protocol client owns the signed request
/// shapes; this type maps its failures and per-item outcomes onto the outbox's
/// vocabulary.
public struct LastFMAdapter: DeliveryAdapter, LastFMLinkClient, LastFMAppCredentialValidating {
    public let kind = ServiceKind.lastFM
    public let capabilities = ServiceCapabilities(
        supportsNowPlaying: true,
        maximumBatchSize: LastFMClient.maximumScrobblesPerBatch,
        supportsLove: true,
        supportsHate: false,
        supportsDelete: false,
        signsRequests: true,
        minimumRequestInterval: 0,
    )

    public let client: LastFMClient

    private let transport: any HTTPTransport
    private let userAgent: String

    /// Last.fm's endpoint is fixed; only the transport and the app credentials
    /// are injected.
    public init(
        transport: any HTTPTransport,
        appCredentials: LastFMAppCredentials,
        userAgent: String = TracklogHTTP.userAgent,
    ) {
        self.transport = transport
        self.userAgent = userAgent
        client = LastFMClient(
            transport: transport,
            appCredentials: appCredentials,
            userAgent: userAgent,
        )
    }

    /// Reads the effective pair per request, so a saved override takes effect
    /// without rebuilding the adapter or the outbox.
    public init(
        transport: any HTTPTransport,
        appCredentials provider: any LastFMAppCredentialsProviding,
        userAgent: String = TracklogHTTP.userAgent,
    ) {
        self.transport = transport
        self.userAgent = userAgent
        client = LastFMClient(
            transport: transport,
            appCredentials: provider,
            userAgent: userAgent,
        )
    }

    /// Checks a candidate pair with Last.fm's token endpoint. It never stores
    /// anything; the app-credentials page saves only after this returns.
    public func validateAppCredentials(_ credentials: LastFMAppCredentials) async throws {
        guard credentials.isConfigured else {
            throw ServiceFailure.appCredentialAuth(.missing)
        }
        let candidate = LastFMClient(
            transport: transport,
            appCredentials: credentials,
            userAgent: userAgent,
        )
        do {
            _ = try await candidate.requestToken()
        } catch {
            throw Self.failure(for: error)
        }
    }

    // MARK: - Link

    public func requestToken() async throws -> LastFMLinkChallenge {
        try await client.requestToken()
    }

    public func session(token: String) async throws -> LastFMSession {
        try await client.session(token: token)
    }

    // MARK: - Connection

    public func validate(_ credential: String, endpoint _: ServiceEndpoint) async throws -> ServiceIdentity {
        do {
            return try await client.userIdentity(sessionKey: credential)
        } catch {
            throw Self.failure(for: error)
        }
    }

    // MARK: - Delivery

    public func submit(
        _ listens: [Listen],
        connection _: Connection,
        credential: String,
    ) async throws -> [DeliveryResult] {
        guard !listens.isEmpty, listens.count <= capabilities.maximumBatchSize else {
            throw ServiceFailure.rejected(
                "Last.fm accepts up to \(LastFMClient.maximumScrobblesPerBatch) scrobbles per request.",
            )
        }
        do {
            let results = try await client.scrobble(listens, sessionKey: credential)
            return results.map { $0.deliveryResult(serviceName: "Last.fm") }
        } catch {
            throw Self.failure(for: error)
        }
    }

    public func submitNowPlaying(
        _ track: Track,
        connection _: Connection,
        credential: String,
    ) async throws -> String? {
        do {
            try await client.updateNowPlaying(track, sessionKey: credential)
            return nil
        } catch {
            throw Self.failure(for: error)
        }
    }

    public func love(_ track: Track, sessionKey: String) async throws {
        do {
            try await client.love(track, sessionKey: sessionKey)
        } catch {
            throw Self.failure(for: error)
        }
    }

    public func unlove(_ track: Track, sessionKey: String) async throws {
        do {
            try await client.unlove(track, sessionKey: sessionKey)
        } catch {
            throw Self.failure(for: error)
        }
    }

    private static func failure(for error: any Error) -> ServiceFailure {
        (error as? LastFMError)?.serviceFailure ?? .retryable
    }
}
