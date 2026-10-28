import Foundation

// MARK: - Delivery

public extension ListenBrainzAdapter {
    func submit(
        _ listens: [Listen],
        connection: Connection,
        credential: String,
    ) async throws -> [DeliveryResult] {
        guard listens.count == 1, let listen = listens.first else {
            throw ServiceFailure.rejected("ListenBrainz accepts one listen per request.")
        }
        let request = try submissionRequest(
            listenType: "single",
            payload: [Self.listenPayload(for: listen)],
            queryItems: [],
            endpoint: connection.endpoint,
            credential: credential,
        )
        let response = try await send(request)
        _ = try successReference(from: response)
        return [.delivered(reference: nil)]
    }

    func submitNowPlaying(
        _ track: Track,
        connection: Connection,
        credential: String,
    ) async throws -> String? {
        let request = try submissionRequest(
            listenType: "playing_now",
            payload: [Self.nowPlayingPayload(for: track)],
            queryItems: [URLQueryItem(name: "return_msid", value: "true")],
            endpoint: connection.endpoint,
            credential: credential,
        )
        let response = try await send(request)
        return try successReference(from: response)
    }

    private func submissionRequest(
        listenType: String,
        payload: [ListenBrainzListen],
        queryItems: [URLQueryItem],
        endpoint: ServiceEndpoint,
        credential: String,
    ) throws -> HTTPRequest {
        let token = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw ServiceFailure.rejected("Enter a user token.") }
        guard var components = URLComponents(string: "\(endpoint.description)/1/submit-listens") else {
            throw ServiceFailure.rejected(nil)
        }
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        guard let url = components.url else { throw ServiceFailure.rejected(nil) }

        let body: Data
        do {
            body = try JSONEncoder().encode(ListenBrainzSubmission(listenType: listenType, payload: payload))
        } catch {
            throw ServiceFailure.rejected(nil)
        }
        return HTTPRequest(
            method: .post,
            url: url,
            headers: [
                "Authorization": "Token \(token)",
                "User-Agent": userAgent,
                "Accept": "application/json",
                "Content-Type": "application/json",
            ],
            body: body,
        )
    }

    private func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        do {
            return try await transport.send(request)
        } catch {
            throw ServiceFailure.retryable
        }
    }

    /// Maps a submission answer onto the one failure taxonomy. A success body
    /// that cannot be read is retryable, never marked delivered.
    private func successReference(from response: HTTPResponse) throws -> String? {
        switch response.statusCode {
        case 200 ..< 300:
            guard let body = try? JSONDecoder().decode(ListenBrainzSubmitResponse.self, from: response.body),
                  body.status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "ok"
            else {
                throw ServiceFailure.retryable
            }
            let reference = body.recordingMSID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return reference.isEmpty ? nil : reference
        case 401, 403:
            throw ServiceFailure.auth
        case 429:
            throw ServiceFailure.rateLimited(retryAfter: retryAfter(from: response))
        case 400 ..< 500:
            throw ServiceFailure.rejected(message(from: response))
        default:
            throw ServiceFailure.retryable
        }
    }
}

// MARK: - Payload

private struct ListenBrainzSubmission: Encodable {
    let listenType: String
    let payload: [ListenBrainzListen]

    enum CodingKeys: String, CodingKey {
        case listenType = "listen_type"
        case payload
    }
}

private struct ListenBrainzListen: Encodable {
    let listenedAt: Int?
    let trackMetadata: ListenBrainzTrackMetadata

    enum CodingKeys: String, CodingKey {
        case listenedAt = "listened_at"
        case trackMetadata = "track_metadata"
    }
}

private struct ListenBrainzTrackMetadata: Encodable {
    let artistName: String
    let trackName: String
    let releaseName: String?
    let additionalInfo: ListenBrainzAdditionalInfo

    enum CodingKeys: String, CodingKey {
        case artistName = "artist_name"
        case trackName = "track_name"
        case releaseName = "release_name"
        case additionalInfo = "additional_info"
    }
}

private struct ListenBrainzAdditionalInfo: Encodable {
    let durationMS: Int?
    let durationPlayed: Int?
    let submissionClient = "Tracklog"
    let submissionClientVersion = TracklogHTTP.version

    enum CodingKeys: String, CodingKey {
        case durationMS = "duration_ms"
        case durationPlayed = "duration_played"
        case submissionClient = "submission_client"
        case submissionClientVersion = "submission_client_version"
    }
}

private struct ListenBrainzSubmitResponse: Decodable {
    let status: String?
    let recordingMSID: String?

    enum CodingKeys: String, CodingKey {
        case status
        case recordingMSID = "recording_msid"
    }
}

private extension ListenBrainzAdapter {
    static func listenPayload(for listen: Listen) -> ListenBrainzListen {
        ListenBrainzListen(
            listenedAt: Int(listen.startedAt.timeIntervalSince1970.rounded()),
            trackMetadata: trackMetadata(
                title: listen.processed.title,
                artist: listen.processed.artist,
                album: listen.processed.album,
                duration: listen.duration,
                playedDuration: listen.playedDuration,
            ),
        )
    }

    static func nowPlayingPayload(for track: Track) -> ListenBrainzListen {
        ListenBrainzListen(
            listenedAt: nil,
            trackMetadata: trackMetadata(
                title: track.title,
                artist: track.artist,
                album: track.album,
                duration: track.duration,
                playedDuration: 0,
            ),
        )
    }

    static func trackMetadata(
        title: String,
        artist: String,
        album: String,
        duration: TimeInterval,
        playedDuration: TimeInterval,
    ) -> ListenBrainzTrackMetadata {
        let durationMS = duration > 0 ? Int((duration * 1000).rounded()) : nil
        let played = playedDuration > 0 ? Int(playedDuration.rounded()) : nil
        let release = album.trimmingCharacters(in: .whitespacesAndNewlines)
        return ListenBrainzTrackMetadata(
            artistName: artist,
            trackName: title,
            releaseName: release.isEmpty ? nil : release,
            additionalInfo: ListenBrainzAdditionalInfo(
                durationMS: durationMS,
                durationPlayed: played,
            ),
        )
    }
}
