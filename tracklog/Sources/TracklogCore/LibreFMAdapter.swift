import Foundation

/// Libre.fm's delivery adapter. It speaks the shared Last.fm 2.0 client with
/// the GNU FM dialect: unsigned calls, one scrobble per request, and the root
/// the listener chose when the connection was linked.
public struct LibreFMAdapter: DeliveryAdapter, FeedbackAdapter {
    public let kind = ServiceKind.libreFM
    public let capabilities = ServiceCapabilities(
        supportsNowPlaying: true,
        maximumBatchSize: LastFMProtocolDialect.gnuFM.maximumScrobblesPerBatch,
        supportsLove: true,
        supportsHate: false,
        supportsDelete: false,
        signsRequests: false,
        minimumRequestInterval: 1,
    )

    /// The message the link page shows when Libre.fm refuses Tracklog's own
    /// key. There is no page where a listener can replace it, so the text
    /// names the key rather than pointing at a remedy that does not exist.
    static let clientKeyRejectionMessage =
        "Libre.fm rejected Tracklog's client key. "
            + "The built-in key is not registered with this server yet."

    private let transport: any HTTPTransport
    private let clientKey: String
    private let userAgent: String

    public init(
        transport: any HTTPTransport,
        clientKey: String = LibreFMClientKey.compiled,
        userAgent: String = TracklogHTTP.userAgent,
    ) {
        self.transport = transport
        self.clientKey = clientKey
        self.userAgent = userAgent
    }

    /// The browser link talks to the one root the listener entered.
    public func linkClient(for endpoint: ServiceEndpoint) -> LibreFMLinkClient {
        LibreFMLinkClient(client: client(for: endpoint))
    }

    private func client(for endpoint: ServiceEndpoint) -> LastFMClient {
        LastFMClient(
            transport: transport,
            appCredentials: LastFMAppCredentials(apiKey: clientKey, sharedSecret: ""),
            endpoint: endpoint,
            dialect: .gnuFM,
            userAgent: userAgent,
        )
    }

    // MARK: - Connection

    public func validate(_ credential: String, endpoint: ServiceEndpoint) async throws -> ServiceIdentity {
        do {
            return try await client(for: endpoint).userIdentity(sessionKey: credential)
        } catch {
            throw Self.linkServiceFailure(for: error)
        }
    }

    // MARK: - Delivery

    public func submit(
        _ listens: [Listen],
        connection: Connection,
        credential: String,
    ) async throws -> [DeliveryResult] {
        guard !listens.isEmpty, listens.count <= capabilities.maximumBatchSize else {
            throw ServiceFailure.rejected("Libre.fm accepts one scrobble per request.")
        }
        do {
            let results = try await client(for: connection.endpoint)
                .scrobble(listens, sessionKey: credential)
            return results.map { $0.deliveryResult(serviceName: "Libre.fm") }
        } catch {
            throw Self.deliveryFailure(for: error)
        }
    }

    public func submitNowPlaying(
        _ track: Track,
        connection: Connection,
        credential: String,
    ) async throws -> String? {
        do {
            try await client(for: connection.endpoint).updateNowPlaying(track, sessionKey: credential)
            return nil
        } catch {
            throw Self.deliveryFailure(for: error)
        }
    }

    /// Sends `track.love` to the connection's own root.
    public func love(_ track: Track, connection: Connection, credential: String) async throws {
        do {
            try await client(for: connection.endpoint).love(track, sessionKey: credential)
        } catch {
            throw Self.deliveryFailure(for: error)
        }
    }

    /// Sends `track.unlove` to the connection's own root.
    public func unlove(_ track: Track, connection: Connection, credential: String) async throws {
        do {
            try await client(for: connection.endpoint).unlove(track, sessionKey: credential)
        } catch {
            throw Self.deliveryFailure(for: error)
        }
    }

    /// The shared feedback port maps onto GNU FM's unsigned love/unlove
    /// calls. GNU FM has no hate action.
    public func submitFeedback(
        _ action: FeedbackAction,
        track: Track,
        reference _: RecordingReference?,
        connection: Connection,
        credential: String,
    ) async throws {
        switch action {
        case .love:
            try await love(track, connection: connection, credential: credential)
        case .unlove:
            try await unlove(track, connection: connection, credential: credential)
        case .hate:
            throw ServiceFailure.rejected("Libre.fm does not support hate.")
        }
    }

    // MARK: - Failures

    /// Whether the service refused the compiled client key rather than the
    /// listener's session.
    private static func isClientKeyRejection(_ error: any Error) -> Bool {
        guard let lastFM = error as? LastFMError else { return false }
        if case .appCredentialAuth = lastFM.serviceFailure {
            return true
        }
        return false
    }

    /// A refused client key is an authentication failure, so the connection
    /// stops delivering and holds its queue: the listen is not at fault and
    /// abandoning it would lose it. The link and validation paths name the key
    /// instead, because signing in again cannot replace a compiled one.
    private static func deliveryFailure(for error: any Error) -> ServiceFailure {
        guard let lastFM = error as? LastFMError else { return .retryable }
        return isClientKeyRejection(error) ? .auth : lastFM.serviceFailure
    }

    /// The link ends inline on a rejected key. Every other protocol error is
    /// passed through untouched, so code 14 still reads as "not authorized
    /// yet" to the page's poll.
    static func linkFailure(for error: any Error) -> any Error {
        if isClientKeyRejection(error) {
            return ServiceFailure.rejected(clientKeyRejectionMessage)
        }
        return (error as? LastFMError) ?? ServiceFailure.retryable
    }

    private static func linkServiceFailure(for error: any Error) -> ServiceFailure {
        if let failure = linkFailure(for: error) as? ServiceFailure {
            return failure
        }
        return (error as? LastFMError)?.serviceFailure ?? .retryable
    }
}
