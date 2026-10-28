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

/// What Last.fm said about one item in a scrobble batch.
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

/// The protocol's failures before they are mapped onto ``ServiceFailure``.
/// The link flow needs to distinguish code 14 (not authorized yet) from a
/// rejected session, so the raw service codes stay available here.
public enum LastFMError: Error, Equatable, Sendable {
    case missingAppCredentials
    case missingSessionKey
    case transport
    case http(statusCode: Int, retryAfter: TimeInterval?)
    case service(code: Int, message: String?)
    case malformedResponse

    /// The one failure taxonomy the rest of the engine speaks.
    public var serviceFailure: ServiceFailure {
        switch self {
        case .missingAppCredentials:
            .appCredentialAuth(.missing)
        case .missingSessionKey:
            .auth
        case .transport:
            .retryable
        case let .http(statusCode, retryAfter):
            switch statusCode {
            case 429: .rateLimited(retryAfter: retryAfter)
            case 401, 403: .auth
            case 500 ..< 600: .retryable
            case 400 ..< 500: .rejected(nil)
            default: .retryable
            }
        case let .service(code, message):
            switch code {
            case 4, 9, 14, 15: .auth
            case 10: .appCredentialAuth(.invalidKey)
            case 13: .appCredentialAuth(.invalidSignature)
            case 26: .appCredentialAuth(.suspendedKey)
            case 8, 11, 16: .retryable
            case 29: .rateLimited(retryAfter: nil)
            case 6, 7: .rejected(message)
            default: .rejected(message)
            }
        case .malformedResponse:
            .retryable
        }
    }
}

/// Last.fm's signed form-post protocol. Every call is a POST to the same
/// endpoint; the signature covers every parameter except `format` and
/// `callback`.
public struct LastFMClient: LastFMLinkClient {
    /// The protocol's hard limit for one `track.scrobble` request.
    public static let maximumScrobblesPerBatch = 50

    public let appCredentials: LastFMAppCredentials
    public let endpoint: ServiceEndpoint
    public let userAgent: String

    private let transport: any HTTPTransport

    /// `endpoint` is fixed to ``ServiceEndpoint/lastFM`` in production. It
    /// stays injectable for fixtures and for the shared Last.fm-protocol
    /// dialect Libre.fm will use.
    public init(
        transport: any HTTPTransport,
        appCredentials: LastFMAppCredentials,
        endpoint: ServiceEndpoint = .lastFM,
        userAgent: String = TracklogHTTP.userAgent,
    ) {
        self.transport = transport
        self.appCredentials = appCredentials
        self.endpoint = endpoint
        self.userAgent = userAgent
    }

    // MARK: - Link

    public func requestToken() async throws -> LastFMLinkChallenge {
        let data = try await perform(method: "auth.getToken")
        let payload = try decode(TokenPayload.self, from: data)
        guard let token = trimmed(payload.token), !token.isEmpty, let url = authorizationURL(for: token) else {
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

    /// Sends `track.scrobble` for one to ``maximumScrobblesPerBatch`` listens,
    /// oldest first, in one form post. The response is read per item; a
    /// missing, unreadable or count-mismatched item throws a retryable failure
    /// so no scrobble is marked delivered on a partial answer.
    public func scrobble(
        _ listens: [Listen],
        sessionKey: String,
    ) async throws -> [LastFMScrobbleResult] {
        guard !listens.isEmpty, listens.count <= Self.maximumScrobblesPerBatch else {
            throw LastFMError.service(
                code: 6,
                message: "A batch must contain 1 to \(Self.maximumScrobblesPerBatch) scrobbles.",
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

    // MARK: - Requests

    func perform(
        method: String,
        parameters: [String: String] = [:],
        sessionKey: String? = nil,
    ) async throws -> Data {
        let request = try makeRequest(method: method, parameters: parameters, sessionKey: sessionKey)
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
    ) throws -> HTTPRequest {
        guard appCredentials.isConfigured else {
            throw LastFMError.missingAppCredentials
        }
        let appKey = apiKey
        let secret = sharedSecret

        var form = parameters
        form["method"] = method
        form["api_key"] = appKey
        if let sessionKey {
            let key = sessionKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { throw LastFMError.missingSessionKey }
            form["sk"] = key
        }
        form["format"] = "json"
        form["api_sig"] = LastFMSignature.signature(parameters: form, sharedSecret: secret)

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

    private var apiKey: String {
        appCredentials.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var sharedSecret: String {
        appCredentials.sharedSecret.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func authorizationURL(for token: String) -> URL? {
        var components = URLComponents(string: LastFMWebEndpoint.authorizationRoot)
        components?.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "token", value: token),
        ]
        return components?.url
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
