import Foundation

/// Last.fm's delivery adapter. The protocol client owns the signed request
/// shapes; this type maps its failures and per-item outcomes onto the outbox's
/// vocabulary.
public struct LastFMAdapter: DeliveryAdapter, LastFMLinkClient {
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

    /// Last.fm's endpoint is fixed; only the transport and the app credentials
    /// are injected.
    public init(
        transport: any HTTPTransport,
        appCredentials: LastFMAppCredentials,
        userAgent: String = TracklogHTTP.userAgent,
    ) {
        client = LastFMClient(
            transport: transport,
            appCredentials: appCredentials,
            userAgent: userAgent,
        )
    }

    // MARK: - Link

    public func requestToken() async throws -> LastFMLinkChallenge {
        try await client.requestToken()
    }

    public func session(token: String) async throws -> LastFMSession {
        try await client.session(token: token)
    }

    // MARK: - Connection

    public func validate(_ credential: String) async throws -> ServiceIdentity {
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
            return results.map(Self.deliveryResult)
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

    private static func deliveryResult(for result: LastFMScrobbleResult) -> DeliveryResult {
        switch result {
        case .accepted:
            .delivered(reference: nil)
        case let .ignored(code):
            switch code {
            case 1 ... 4:
                .rejected(reason: "Last.fm ignored this scrobble (code \(code)).")
            case 5:
                .rateLimited(retryAfter: nil)
            default:
                .rejected(reason: "Last.fm ignored this scrobble (code \(code)).")
            }
        }
    }
}
