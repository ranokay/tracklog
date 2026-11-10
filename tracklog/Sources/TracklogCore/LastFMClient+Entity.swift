import Foundation

// MARK: - Last.fm getInfo

/// One `getInfo` answer. `value` is nil when the body did not decode to the
/// entity object; `trace` describes the answer's shape either way, so the
/// adapter can log what an unreadable answer looked like.
struct LastFMEntityRead<Value> {
    let value: Value?
    let trace: LastFMEntityAnswerTrace
}

extension LastFMClient {
    func artistInfo(
        artist: String,
        username: String?,
    ) async throws -> LastFMEntityRead<LastFMArtistInfoValue> {
        try await entityRead(
            method: "artist.getInfo",
            entityKey: "artist",
            parameters: identityParameters(artist: artist, username: username),
            payload: LastFMArtistInfoPayload.self,
            value: \.artist,
        )
    }

    func albumInfo(
        album: String,
        artist: String,
        username: String?,
    ) async throws -> LastFMEntityRead<LastFMAlbumInfoValue> {
        var parameters = try identityParameters(artist: artist, username: username)
        parameters["album"] = album.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await entityRead(
            method: "album.getInfo",
            entityKey: "album",
            parameters: parameters,
            payload: LastFMAlbumInfoPayload.self,
            value: \.album,
        )
    }

    func trackInfo(
        track: String,
        artist: String,
        username: String?,
    ) async throws -> LastFMEntityRead<LastFMTrackInfoValue> {
        var parameters = try identityParameters(artist: artist, username: username)
        parameters["track"] = track.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await entityRead(
            method: "track.getInfo",
            entityKey: "track",
            parameters: parameters,
            payload: LastFMTrackInfoPayload.self,
            value: \.track,
        )
    }

    /// Sends one unsigned-session read and decodes its entity. A body that
    /// does not decode is a read with no value, not a thrown error, so the
    /// caller can log the shape before it classifies the answer.
    private func entityRead<Payload: Decodable, Value>(
        method: String,
        entityKey: String,
        parameters: [String: String],
        payload _: Payload.Type,
        value: KeyPath<Payload, Value?>,
    ) async throws -> LastFMEntityRead<Value> {
        let credentials = try await resolvedCredentials()
        let response = try await checkedResponse(
            method: method,
            parameters: parameters,
            sessionKey: nil,
            credentials: credentials,
        )
        let trace = LastFMEntityAnswerTrace(method: method, entityKey: entityKey, response: response)
        do {
            let decoded = try JSONDecoder().decode(Payload.self, from: response.body)
            return LastFMEntityRead(value: decoded[keyPath: value], trace: trace)
        } catch {
            return LastFMEntityRead(value: nil, trace: trace.recordingDecodeFailure(error))
        }
    }

    private func identityParameters(artist: String, username: String?) throws -> [String: String] {
        let artist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !artist.isEmpty else {
            throw LastFMError.service(code: 6, message: "Artist and track are required.")
        }
        var parameters = ["artist": artist]
        let user = username?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !user.isEmpty {
            parameters["username"] = user
        }
        return parameters
    }
}

// MARK: - Service adapter

/// The entity-detail half of the Last.fm adapter. It uses the same client and
/// the same `LastFMError` classification as every other Last.fm read.
extension LastFMAdapter: EntityServiceReading {
    public func entityDetails(
        _ request: EntityRequest,
        connection: Connection,
    ) async throws -> EntityServiceFacts {
        do {
            switch request.kind {
            case .artist:
                return try await artistDetails(request, connection: connection)
            case .album:
                return try await albumDetails(request, connection: connection)
            case .track:
                return try await trackDetails(request, connection: connection)
            }
        } catch {
            throw Self.entityServiceError(for: error)
        }
    }

    private func artistDetails(
        _ request: EntityRequest,
        connection: Connection,
    ) async throws -> EntityServiceFacts {
        let read = try await client.artistInfo(
            artist: request.title,
            username: connection.identity,
        )
        guard let info = read.value else { throw unreadable(read.trace) }
        var facts: [EntityFact] = []
        appendCount(info.stats?.listeners, label: "Listeners on Last.fm", to: &facts)
        appendCount(info.stats?.playcount, label: "Plays on Last.fm", to: &facts)
        appendCount(info.stats?.userplaycount, label: "Your plays", to: &facts)
        return try usable(EntityServiceFacts(
            serviceName: "Last.fm",
            accountName: connection.displayName,
            facts: facts,
            link: httpsURL(info.url),
        ), trace: read.trace)
    }

    private func albumDetails(
        _ request: EntityRequest,
        connection: Connection,
    ) async throws -> EntityServiceFacts {
        let read = try await client.albumInfo(
            album: request.title,
            artist: request.subtitle,
            username: connection.identity,
        )
        guard let info = read.value else { throw unreadable(read.trace) }
        var facts: [EntityFact] = []
        if let released = releaseDate(info.releasedate) {
            facts.append(EntityFact(label: "Released", value: released))
        }
        appendCount(info.listeners, label: "Listeners on Last.fm", to: &facts)
        appendCount(info.playcount, label: "Plays on Last.fm", to: &facts)
        appendCount(info.userplaycount, label: "Your plays", to: &facts)
        return try usable(EntityServiceFacts(
            serviceName: "Last.fm",
            accountName: connection.displayName,
            facts: facts,
            link: httpsURL(info.url),
            artworkURL: largestImage(info.image),
        ), trace: read.trace)
    }

    private func trackDetails(
        _ request: EntityRequest,
        connection: Connection,
    ) async throws -> EntityServiceFacts {
        let read = try await client.trackInfo(
            track: request.title,
            artist: request.subtitle,
            username: connection.identity,
        )
        guard let info = read.value else { throw unreadable(read.trace) }
        var facts: [EntityFact] = []
        if let duration = info.duration?.value, duration > 0 {
            facts.append(EntityFact(label: "Duration", value: durationText(milliseconds: duration)))
        }
        appendCount(info.listeners, label: "Listeners on Last.fm", to: &facts)
        appendCount(info.playcount, label: "Plays on Last.fm", to: &facts)
        appendCount(info.userplaycount, label: "Your plays", to: &facts)
        return try usable(EntityServiceFacts(
            serviceName: "Last.fm",
            accountName: connection.displayName,
            facts: facts,
            link: httpsURL(info.url),
        ), trace: read.trace)
    }

    /// A decoded entity object that carries no fact and no link is not a
    /// success: it would draw an empty service section and hide a shape
    /// change. Treat it as an unreadable answer instead.
    private func usable(
        _ facts: EntityServiceFacts,
        trace: LastFMEntityAnswerTrace,
    ) throws -> EntityServiceFacts {
        guard !facts.facts.isEmpty || facts.link != nil else {
            throw unreadable(trace.rejectingEmptyEntity())
        }
        return facts
    }

    /// Logs the answer's shape through the diagnostics sink, then returns the
    /// failure the page shows. Only an unreadable answer is logged.
    private func unreadable(_ trace: LastFMEntityAnswerTrace) -> EntityServiceFailure {
        entityDiagnostics?(trace.logLine)
        return .unreadable
    }

    private func appendCount(
        _ value: LastFMFlexibleInt?,
        label: String,
        to facts: inout [EntityFact],
    ) {
        guard let count = value?.value else { return }
        facts.append(EntityFact(label: label, value: count.formatted()))
    }

    private func releaseDate(_ value: String?) -> String? {
        let text = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty, !text.lowercased().contains("unknown") else { return nil }
        if let range = text.range(of: ", 00:00") {
            return String(text[..<range.lowerBound])
        }
        return text
    }

    private func durationText(milliseconds: Int) -> String {
        let seconds = max(0, milliseconds / 1000)
        return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }

    private func largestImage(_ images: [LastFMImageValue]?) -> URL? {
        guard let images else { return nil }
        let order = ["mega", "extralarge", "large", "medium", "small"]
        for size in order {
            if let text = images.first(where: { $0.size == size })?.text,
               let url = httpsURL(text) {
                return url
            }
        }
        for image in images.reversed() {
            if let url = httpsURL(image.text) {
                return url
            }
        }
        return nil
    }

    /// The Search API returns images over https today, but an older answer can
    /// still carry http. The request itself stays https; only the scheme is
    /// promoted, never credentials or a different host.
    private func httpsURL(_ value: String?) -> URL? {
        guard var components = URLComponents(
                  string: value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
              ),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil
        else { return nil }
        if components.scheme?.lowercased() == "http" {
            components.scheme = "https"
        }
        guard components.scheme?.lowercased() == "https" else { return nil }
        return components.url
    }

    private static func entityServiceError(for error: any Error) -> any Error {
        if let readError = error as? EntityServiceReadError {
            return readError
        }
        if let failure = error as? EntityServiceFailure {
            return failure
        }
        guard let lastFM = error as? LastFMError else {
            return EntityServiceFailure.unexpected
        }
        if let failure = concreteFailure(for: lastFM) {
            return failure
        }
        return classifiedFailure(for: lastFM)
    }

    /// Classify the concrete error before `serviceFailure`: transport,
    /// credential storage, malformed answers and 5xx all collapse into
    /// `.retryable` there, and the page must not call them all unreachable.
    private static func concreteFailure(for error: LastFMError) -> EntityServiceFailure? {
        switch error {
        case .transport:
            .offline
        case .credentialStorage:
            .credentialsUnavailable
        case .malformedResponse:
            .unreadable
        case let .http(statusCode, _) where (500 ..< 600).contains(statusCode):
            .serviceUnavailable
        case let .service(code, _) where [8, 11, 16].contains(code):
            .serviceUnavailable
        default:
            nil
        }
    }

    private static func classifiedFailure(for error: LastFMError) -> any Error {
        switch error.serviceFailure {
        case let .appCredentialAuth(problem):
            return EntityServiceFailure.appCredentials(problem)
        case .auth:
            return EntityServiceFailure.needsSignIn
        case let .rateLimited(retryAfter):
            return EntityServiceFailure.rateLimited(retryAfter: retryAfter)
        case .retryable:
            // Transport, credential storage, malformed answers and 5xx are
            // handled above. What remains retryable is an HTTP status the
            // transport refused, such as a redirect that would drop HTTPS.
            return EntityServiceFailure.serviceUnavailable
        case let .rejected(message):
            if isNotFound(message) {
                return EntityServiceReadError.missing
            }
            return EntityServiceFailure.service(message)
        }
    }

    private static func isNotFound(_ message: String?) -> Bool {
        let value = message?.lowercased() ?? ""
        return value.contains("could not be found") || value.contains("not found")
    }
}

public enum EntityServiceReadError: Error, Equatable, Sendable {
    case missing
}
