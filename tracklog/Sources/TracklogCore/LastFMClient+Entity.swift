import Foundation

// MARK: - Last.fm getInfo

/// One entity read: the value when the entity decoded, and every attempt made
/// to get it, in order. `value` is nil when the last answer held no entity.
struct LastFMEntityRead<Value> {
    let value: Value?
    let attempts: [LastFMEntityAttempt]
}

/// A read that stopped on a refused attempt. The attempts so far travel with
/// the error, so the adapter can log them before it classifies the error.
struct LastFMEntityReadFailure: Error {
    let underlying: any Error
    let attempts: [LastFMEntityAttempt]
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

    /// Reads one entity. The original signed POST goes first. Only an answer
    /// that is an empty JSON object retries, through the variants in order, and
    /// the first answer that is not an empty object ends the sequence. A refused
    /// attempt throws, so the service's own classification still applies.
    private func entityRead<Payload: Decodable, Value>(
        method: String,
        entityKey: String,
        parameters: [String: String],
        payload: Payload.Type,
        value: KeyPath<Payload, Value?>,
    ) async throws -> LastFMEntityRead<Value> {
        let credentials = try await resolvedCredentials()
        var attempts: [LastFMEntityAttempt] = []
        for (variant, sent) in Self.entityVariants(parameters) {
            let response: HTTPResponse
            do {
                response = try await checkedResponse(
                    method: method,
                    parameters: sent,
                    sessionKey: nil,
                    credentials: credentials,
                    verb: variant.verb,
                )
            } catch {
                attempts.append(LastFMEntityAttempt(
                    method: method,
                    variant: variant,
                    answer: nil,
                    refusal: Self.refusal(for: error),
                ))
                throw LastFMEntityReadFailure(underlying: error, attempts: attempts)
            }
            let (answer, decoded) = Self.decodeEntity(
                response,
                method: method,
                entityKey: entityKey,
                payload: payload,
                value: value,
            )
            attempts.append(LastFMEntityAttempt(
                method: method,
                variant: variant,
                answer: answer,
                refusal: nil,
            ))
            if !answer.emptyObject {
                return LastFMEntityRead(value: decoded, attempts: attempts)
            }
        }
        return LastFMEntityRead(value: nil, attempts: attempts)
    }

    /// The attempts in the order they are made. Without a `username` there is
    /// nothing to drop, so only the signed POST and its GET twin run.
    private static func entityVariants(
        _ parameters: [String: String],
    ) -> [(LastFMEntityVariant, [String: String])] {
        guard parameters["username"] != nil else {
            return [(.post, parameters), (.get, parameters)]
        }
        var withoutUsername = parameters
        withoutUsername["username"] = nil
        return [
            (.post, parameters),
            (.get, parameters),
            (.postNoUsername, withoutUsername),
            (.getNoUsername, withoutUsername),
        ]
    }

    /// The answer's shape, and the decoded entity when it decodes. A body that
    /// does not decode is an answer with no value, not a thrown error.
    private static func decodeEntity<Payload: Decodable, Value>(
        _ response: HTTPResponse,
        method: String,
        entityKey: String,
        payload: Payload.Type,
        value: KeyPath<Payload, Value?>,
    ) -> (LastFMEntityAnswerTrace, Value?) {
        let answer = LastFMEntityAnswerTrace(method: method, entityKey: entityKey, response: response)
        do {
            let decoded = try JSONDecoder().decode(payload, from: response.body)
            return (answer, decoded[keyPath: value])
        } catch {
            return (answer.recordingDecodeFailure(error), nil)
        }
    }

    /// The reason a refused attempt gives. It names the service's code or the
    /// HTTP status, never the message or the body.
    private static func refusal(for error: any Error) -> String {
        guard let lastFM = error as? LastFMError else { return "other" }
        switch lastFM {
        case let .http(statusCode, _): return "http-\(statusCode)"
        case let .service(code, _): return "service-\(code)"
        case .transport: return "transport"
        case .credentialStorage: return "credentials"
        case .malformedResponse: return "malformed"
        case .missingAppCredentials: return "app-credentials"
        case .missingSessionKey: return "session-key"
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
