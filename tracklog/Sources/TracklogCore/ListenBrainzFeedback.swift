import Foundation

// MARK: - Feedback

extension ListenBrainzAdapter: FeedbackAdapter {
    /// ListenBrainz needs a recording MSID or MBID for the feedback endpoint.
    public var requiresReference: Bool {
        true
    }

    /// Resolves the recording MBID from the track's artist, title and album.
    /// This is the action-time fallback when no delivery row kept a reference.
    public func resolveReference(
        for track: Track,
        connection: Connection,
        credential: String,
    ) async throws -> RecordingReference? {
        let token = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw ServiceFailure.rejected("Enter a user token.") }
        let title = track.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = track.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !artist.isEmpty else {
            throw ServiceFailure.rejected("ListenBrainz needs a title and artist to match that recording.")
        }
        guard var components = URLComponents(
            string: "\(connection.endpoint.description)/1/metadata/lookup/",
        ) else {
            throw ServiceFailure.rejected(nil)
        }
        var query = [
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "recording_name", value: title),
        ]
        let album = track.album.trimmingCharacters(in: .whitespacesAndNewlines)
        if !album.isEmpty {
            query.append(URLQueryItem(name: "release_name", value: album))
        }
        components.queryItems = query
        guard let url = components.url else { throw ServiceFailure.rejected(nil) }

        let request = HTTPRequest(
            method: .get,
            url: url,
            headers: [
                "Authorization": "Token \(token)",
                "User-Agent": userAgent,
                "Accept": "application/json",
            ],
        )
        let response = try await send(request)
        try ensureSuccess(response)
        guard let body = try? JSONDecoder().decode(LookupResponse.self, from: response.body) else {
            throw ServiceFailure.retryable
        }
        if let mbid = body.recordingMBID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !mbid.isEmpty {
            return .mbid(mbid)
        }
        if let msid = body.recordingMSID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !msid.isEmpty {
            return .msid(msid)
        }
        throw ServiceFailure.rejected("ListenBrainz could not match that recording.")
    }

    /// Posts one love, hate or reset to the recording feedback endpoint.
    public func submitFeedback(
        _ action: FeedbackAction,
        track _: Track,
        reference: RecordingReference?,
        connection: Connection,
        credential: String,
    ) async throws {
        let token = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw ServiceFailure.rejected("Enter a user token.") }
        guard let reference else {
            throw ServiceFailure.rejected("ListenBrainz needs a recording reference.")
        }
        guard let url = URL(
            string: "\(connection.endpoint.description)/1/feedback/recording-feedback",
        ) else {
            throw ServiceFailure.rejected(nil)
        }

        let body: Data
        do {
            body = try JSONEncoder().encode(FeedbackBody(reference: reference, score: action.score))
        } catch {
            throw ServiceFailure.rejected(nil)
        }
        let request = HTTPRequest(
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
        let response = try await send(request)
        try ensureSuccess(response)
    }

    private func ensureSuccess(_ response: HTTPResponse) throws {
        switch response.statusCode {
        case 200 ..< 300:
            return
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

    private func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        do {
            return try await transport.send(request)
        } catch {
            throw ServiceFailure.retryable
        }
    }
}

private extension FeedbackAction {
    var score: Int {
        switch self {
        case .love: 1
        case .unlove: 0
        case .hate: -1
        }
    }
}

private struct FeedbackBody: Encodable {
    let reference: RecordingReference
    let score: Int

    enum CodingKeys: String, CodingKey {
        case recordingMSID = "recording_msid"
        case recordingMBID = "recording_mbid"
        case score
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch reference {
        case let .msid(value):
            try container.encode(value, forKey: .recordingMSID)
        case let .mbid(value):
            try container.encode(value, forKey: .recordingMBID)
        }
        try container.encode(score, forKey: .score)
    }
}

private struct LookupResponse: Decodable {
    let recordingMBID: String?
    let recordingMSID: String?

    enum CodingKeys: String, CodingKey {
        case recordingMBID = "recording_mbid"
        case recordingMSID = "recording_msid"
    }
}
