import Foundation

// MARK: - Last.fm getInfo

/// One entity read: the value when the entity decoded, and the shape of the
/// answer it came from. `value` is nil when the answer held no entity object.
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

    /// Reads one entity with one signed GET. The GET is the verb Last.fm
    /// documents for `getInfo`; a signed POST to these methods answers `{}`.
    /// A body that does not decode is a read with no value, not a thrown error.
    private func entityRead<Payload: Decodable, Value>(
        method: String,
        entityKey: String,
        parameters: [String: String],
        payload: Payload.Type,
        value: KeyPath<Payload, Value?>,
    ) async throws -> LastFMEntityRead<Value> {
        let credentials = try await resolvedCredentials()
        let response = try await checkedResponse(
            method: method,
            parameters: parameters,
            sessionKey: nil,
            credentials: credentials,
            verb: .get,
        )
        let trace = LastFMEntityAnswerTrace(method: method, entityKey: entityKey, response: response)
        do {
            let decoded = try JSONDecoder().decode(payload, from: response.body)
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
