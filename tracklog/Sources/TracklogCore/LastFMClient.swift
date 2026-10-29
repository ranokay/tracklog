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

/// Last.fm's signed form-post protocol. Every call is a POST to the same
/// endpoint; the signature covers every parameter except `format` and
/// `callback`.
public struct LastFMClient: LastFMLinkClient {
    /// Last.fm's hard limit for one `track.scrobble` request. GNU FM's limit
    /// comes from ``LastFMProtocolDialect/maximumScrobblesPerBatch``.
    public static let maximumScrobblesPerBatch = LastFMProtocolDialect.lastFM.maximumScrobblesPerBatch

    public let endpoint: ServiceEndpoint
    public let dialect: LastFMProtocolDialect
    public let userAgent: String

    private let transport: any HTTPTransport
    private let credentialsProvider: any LastFMAppCredentialsProviding

    /// `endpoint` is fixed to ``ServiceEndpoint/lastFM`` in production. It
    /// stays injectable for fixtures and for the GNU FM dialect Libre.fm uses,
    /// whose root the listener chooses at link time.
    public init(
        transport: any HTTPTransport,
        appCredentials: LastFMAppCredentials,
        endpoint: ServiceEndpoint = .lastFM,
        dialect: LastFMProtocolDialect = .lastFM,
        userAgent: String = TracklogHTTP.userAgent,
    ) {
        self.init(
            transport: transport,
            appCredentials: FixedLastFMAppCredentials(appCredentials),
            endpoint: endpoint,
            dialect: dialect,
            userAgent: userAgent,
        )
    }

    /// Reads the effective pair through a provider, so a Keychain override
    /// saved while the client is alive is used by the next signed call.
    public init(
        transport: any HTTPTransport,
        appCredentials provider: any LastFMAppCredentialsProviding,
        endpoint: ServiceEndpoint = .lastFM,
        dialect: LastFMProtocolDialect = .lastFM,
        userAgent: String = TracklogHTTP.userAgent,
    ) {
        self.transport = transport
        credentialsProvider = provider
        self.endpoint = endpoint
        self.dialect = dialect
        self.userAgent = userAgent
    }

    // MARK: - Link

    public func requestToken() async throws -> LastFMLinkChallenge {
        let credentials = try await resolvedCredentials()
        let data = try await perform(
            method: "auth.getToken",
            parameters: [:],
            sessionKey: nil,
            credentials: credentials,
        )
        let payload = try decode(TokenPayload.self, from: data)
        guard let token = trimmed(payload.token), !token.isEmpty,
              let url = authorizationURL(for: token, apiKey: credentials.apiKey)
        else {
            throw LastFMError.malformedResponse
        }
        return LastFMLinkChallenge(token: token, authorizationURL: url)
    }

    public func session(token: String) async throws -> LastFMSession {
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw LastFMError.missingSessionKey }
        let data = try await perform(
            method: "auth.getSession",
            parameters: ["token": value],
        )
        let payload = try decode(SessionPayload.self, from: data)
        guard let session = payload.session,
              let name = trimmed(session.name), !name.isEmpty,
              let key = trimmed(session.key), !key.isEmpty
        else {
            throw LastFMError.malformedResponse
        }
        return LastFMSession(name: name, key: key)
    }

    public func userIdentity(sessionKey: String) async throws -> ServiceIdentity {
        let data = try await perform(method: "user.getInfo", sessionKey: sessionKey)
        let payload = try decode(UserPayload.self, from: data)
        guard let name = trimmed(payload.user?.name), !name.isEmpty else {
            throw LastFMError.malformedResponse
        }
        return ServiceIdentity(name: name)
    }

    // MARK: - Delivery

    /// Sends `track.updateNowPlaying` for one track. The artist and title must
    /// be non-empty; a missing pair throws a rejected service failure. Now
    /// playing is never queued or retried by the caller.
    public func updateNowPlaying(_ track: Track, sessionKey: String) async throws {
        let parameters = try metadataParameters(
            title: track.title,
            artist: track.artist,
            album: track.album,
            albumArtist: track.albumArtist,
            duration: track.duration,
        )
        _ = try await perform(
            method: "track.updateNowPlaying",
            parameters: parameters,
            sessionKey: sessionKey,
        )
    }

    /// Sends `track.scrobble` for one to the dialect's batch limit listens,
    /// oldest first, in one form post. The response is read per item; a
    /// missing, unreadable or count-mismatched item throws a retryable failure
    /// so no scrobble is marked delivered on a partial answer.
    public func scrobble(
        _ listens: [Listen],
        sessionKey: String,
    ) async throws -> [LastFMScrobbleResult] {
        let limit = dialect.maximumScrobblesPerBatch
        guard !listens.isEmpty, listens.count <= limit else {
            throw LastFMError.service(
                code: 6,
                message: "A batch must contain 1 to \(limit) scrobbles.",
            )
        }
        var parameters: [String: String] = [:]
        for (index, listen) in listens.enumerated() {
            let fields = try metadataParameters(
                title: listen.processed.title,
                artist: listen.processed.artist,
                album: listen.processed.album,
                albumArtist: listen.processed.albumArtist,
                duration: listen.duration,
            )
            for (name, value) in fields {
                parameters["\(name)[\(index)]"] = value
            }
            let timestamp = Int(listen.startedAt.timeIntervalSince1970.rounded())
            parameters["timestamp[\(index)]"] = String(timestamp)
        }

        let data = try await perform(
            method: "track.scrobble",
            parameters: parameters,
            sessionKey: sessionKey,
        )
        let payload = try decode(ScrobblePayload.self, from: data)
        guard let items = payload.scrobbles?.scrobble?.items,
              items.count == listens.count
        else {
            throw LastFMError.malformedResponse
        }
        return try items.map { item in
            guard let ignored = item.ignoredMessage, let code = ignored.code else {
                // The count matched but the item cannot be read. Treating it
                // as delivered would lose a scrobble silently.
                throw LastFMError.malformedResponse
            }
            return code == 0 ? .accepted : .ignored(code: code)
        }
    }

    private func authorizationURL(for token: String, apiKey: String) -> URL? {
        dialect.authorizationURL(endpoint: endpoint, token: token, apiKey: apiKey)
    }

    func identityParameters(title: String, artist: String) throws -> [String: String] {
        let artist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !artist.isEmpty, !title.isEmpty else {
            throw LastFMError.service(code: 6, message: "Artist and track are required.")
        }
        return ["artist": artist, "track": title]
    }

    private func metadataParameters(
        title: String,
        artist: String,
        album: String,
        albumArtist: String,
        duration: TimeInterval?,
    ) throws -> [String: String] {
        var parameters = try identityParameters(title: title, artist: artist)
        let album = album.trimmingCharacters(in: .whitespacesAndNewlines)
        if !album.isEmpty {
            parameters["album"] = album
        }
        let albumArtist = albumArtist.trimmingCharacters(in: .whitespacesAndNewlines)
        if !albumArtist.isEmpty {
            parameters["albumArtist"] = albumArtist
        }
        if let duration, duration > 0 {
            parameters["duration"] = String(Int(duration.rounded()))
        }
        return parameters
    }

    private func retryAfter(from response: HTTPResponse) -> TimeInterval? {
        for name in ["Retry-After", "X-RateLimit-Reset-In"] {
            guard let value = response.header(name)?.trimmingCharacters(in: .whitespaces),
                  let seconds = TimeInterval(value)
            else { continue }
            return seconds
        }
        return nil
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        guard let value = try? JSONDecoder().decode(type, from: data) else {
            throw LastFMError.malformedResponse
        }
        return value
    }

    private func trimmed(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func formEncode(_ parameters: [String: String]) -> String {
        parameters
            .sorted { $0.key < $1.key }
            .map { "\(escape($0.key))=\(escape($0.value))" }
            .joined(separator: "&")
    }

    private static func escape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: formAllowed) ?? ""
    }

    private static let formAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~",
    )
}

extension LastFMClient {
    // MARK: - Requests

    /// Reads the effective pair. A credential-store failure is its own error:
    /// falling back to the compiled pair could sign with the wrong account.
    private func resolvedCredentials() async throws -> LastFMAppCredentials {
        do {
            return try await credentialsProvider.appCredentials()
        } catch {
            throw LastFMError.credentialStorage
        }
    }

    func perform(
        method: String,
        parameters: [String: String] = [:],
        sessionKey: String? = nil,
    ) async throws -> Data {
        let credentials = try await resolvedCredentials()
        return try await perform(
            method: method,
            parameters: parameters,
            sessionKey: sessionKey,
            credentials: credentials,
        )
    }

    private func perform(
        method: String,
        parameters: [String: String],
        sessionKey: String?,
        credentials: LastFMAppCredentials,
    ) async throws -> Data {
        let request = try makeRequest(
            method: method,
            parameters: parameters,
            sessionKey: sessionKey,
            credentials: credentials,
        )
        let response: HTTPResponse
        do {
            response = try await transport.send(request)
        } catch {
            throw LastFMError.transport
        }

        // A 429 is a rate limit even when the body also names a service error,
        // and its Retry-After header is the hint the outbox needs.
        if response.statusCode == 429 {
            throw LastFMError.http(statusCode: 429, retryAfter: retryAfter(from: response))
        }

        // A 5xx is a server failure even when the body names a service error.
        // The body's code must not turn a retryable outage into an auth or
        // rejection decision.
        if (500 ..< 600).contains(response.statusCode) {
            throw LastFMError.http(
                statusCode: response.statusCode,
                retryAfter: retryAfter(from: response),
            )
        }

        // Last.fm can answer HTTP 200 with an error document. Inspect the body
        // before trusting the status code.
        if let payload = try? JSONDecoder().decode(ErrorPayload.self, from: response.body),
           let code = payload.error, code != 0 {
            throw LastFMError.service(code: code, message: trimmed(payload.message))
        }

        if (200 ..< 300).contains(response.statusCode) {
            return response.body
        }
        throw LastFMError.http(
            statusCode: response.statusCode,
            retryAfter: retryAfter(from: response),
        )
    }

    private func makeRequest(
        method: String,
        parameters: [String: String],
        sessionKey: String?,
        credentials: LastFMAppCredentials,
    ) throws -> HTTPRequest {
        let appKey = credentials.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = credentials.sharedSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        // A signed dialect needs both halves; an unsigned one is keyed by its
        // client key alone and never issues a secret.
        guard !appKey.isEmpty, !dialect.requiresSharedSecret || !secret.isEmpty else {
            throw LastFMError.missingAppCredentials
        }

        var form = parameters
        form["method"] = method
        form["api_key"] = appKey
        if let sessionKey {
            let key = sessionKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { throw LastFMError.missingSessionKey }
            form["sk"] = key
        }
        form["format"] = "json"
        if dialect.signsRequests {
            form["api_sig"] = LastFMSignature.signature(parameters: form, sharedSecret: secret)
        }

        guard let url = URL(string: "\(endpoint.description)/2.0/") else {
            throw LastFMError.malformedResponse
        }
        return HTTPRequest(
            method: .post,
            url: url,
            headers: [
                "Content-Type": "application/x-www-form-urlencoded; charset=utf-8",
                "User-Agent": userAgent,
                "Accept": "application/json",
            ],
            body: Data(Self.formEncode(form).utf8),
        )
    }
}
