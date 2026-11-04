import Foundation

// MARK: - ListenBrainz loved reads

extension ListenBrainzAdapter: LovedServiceReading {
    public var firstCursor: LovedCursor {
        .offset(0)
    }

    /// The account's positive recording feedback. ListenBrainz paginates by
    /// raw feedback offset and can return entries whose recording has no
    /// track metadata; those entries are counted, never named with a guess.
    public func loved(
        connection: Connection,
        credential: String,
        cursor: LovedCursor,
        limit: Int,
    ) async throws -> LovedServicePage {
        guard case let .offset(offset) = cursor else {
            throw ServiceFailure.rejected("ListenBrainz loved tracks are read by offset.")
        }
        let pageSize = max(1, limit)
        let request = try lovedRequest(
            account: connection.identity,
            offset: max(0, offset),
            limit: pageSize,
            endpoint: connection.endpoint,
            credential: credential,
        )
        let response: HTTPResponse
        do {
            response = try await transport.send(request)
        } catch {
            throw ServiceFailure.retryable
        }

        switch response.statusCode {
        case 204:
            return LovedServicePage(rows: [], nextCursor: nil)
        case 200 ..< 300:
            return try Self.page(
                from: response.body,
                connection: connection,
                offset: max(0, offset),
                limit: pageSize,
            )
        default:
            throw Self.statusFailure(response, connection: connection)
        }
    }

    private static func statusFailure(
        _ response: HTTPResponse,
        connection: Connection,
    ) -> any Error {
        switch response.statusCode {
        case 401, 403:
            ServiceFailure.auth
        case 404:
            if connection.endpoint == .listenBrainz {
                ServiceFailure.rejected("ListenBrainz could not find that account.")
            } else {
                LovedServiceError.unsupported(
                    "This ListenBrainz-compatible server does not provide loved tracks.",
                )
            }
        case 405, 501:
            LovedServiceError.unsupported(
                "This ListenBrainz-compatible server does not provide loved tracks.",
            )
        case 429:
            ServiceFailure.rateLimited(retryAfter: ChartServiceHTTP.retryAfter(from: response))
        case 400 ..< 500:
            ServiceFailure.rejected(errorMessage(from: response))
        default:
            ServiceFailure.retryable
        }
    }

    private func lovedRequest(
        account: String,
        offset: Int,
        limit: Int,
        endpoint: ServiceEndpoint,
        credential: String,
    ) throws -> HTTPRequest {
        guard var components = try URLComponents(
            string: "\(endpoint.description)/1/feedback/user/"
                + "\(Self.encodedAccount(account))/get-feedback",
        ) else { throw ServiceFailure.rejected(nil) }
        components.queryItems = [
            URLQueryItem(name: "score", value: "1"),
            URLQueryItem(name: "count", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "metadata", value: "true"),
        ]
        guard let url = components.url else { throw ServiceFailure.rejected(nil) }
        var headers = [
            "User-Agent": userAgent,
            "Accept": "application/json",
        ]
        let token = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty {
            headers["Authorization"] = "Token \(token)"
        }
        return HTTPRequest(method: .get, url: url, headers: headers)
    }

    private static func page(
        from body: Data,
        connection: Connection,
        offset: Int,
        limit: Int,
    ) throws -> LovedServicePage {
        guard let payload = try? JSONDecoder().decode(ListenBrainzFeedbackPayload.self, from: body)
        else { throw ServiceFailure.retryable }
        let items = payload.feedback ?? []
        var omitted = 0
        let rows = items.compactMap { item -> LovedRow? in
            guard let metadata = item.trackMetadata,
                  let title = trimmed(metadata.trackName), !title.isEmpty,
                  let artist = trimmed(metadata.artistName), !artist.isEmpty
            else {
                omitted += 1
                return nil
            }
            let album = trimmed(metadata.releaseName) ?? ""
            let mbid = trimmed(item.recordingMbid) ?? ""
            let msid = trimmed(item.recordingMsid) ?? ""
            let reference: RecordingReference? = if !mbid.isEmpty {
                .mbid(mbid)
            } else if !msid.isEmpty {
                .msid(msid)
            } else {
                nil
            }
            let id = if !mbid.isEmpty {
                "listenbrainz:mbid:\(mbid)"
            } else if !msid.isEmpty {
                "listenbrainz:msid:\(msid)"
            } else {
                "listenbrainz:track:\(Identity.joined([title, artist, album]))"
            }
            return LovedRow(
                connectionID: connection.id,
                id: id,
                title: title,
                artist: artist,
                album: album,
                reference: reference,
            )
        }
        let nextCursor: LovedCursor? = if items.isEmpty {
            // A stale or filtered total must not repeat the offset just read.
            nil
        } else if let total = payload.totalCount {
            offset + items.count < total ? .offset(offset + items.count) : nil
        } else {
            items.count >= limit ? .offset(offset + items.count) : nil
        }
        return LovedServicePage(rows: rows, omitted: omitted, nextCursor: nextCursor)
    }

    private static func encodedAccount(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ServiceFailure.rejected("A ListenBrainz account is required.")
        }
        var allowed = CharacterSet.alphanumerics
        allowed.formUnion(CharacterSet(charactersIn: "-._~"))
        guard let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw ServiceFailure.rejected("That ListenBrainz account cannot be requested.")
        }
        return encoded
    }

    private static func errorMessage(from response: HTTPResponse) -> String? {
        guard let payload = try? JSONDecoder().decode(ListenBrainzFeedbackErrorPayload.self, from: response.body)
        else { return nil }
        let text = payload.error ?? payload.message
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func trimmed(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Payloads

private struct ListenBrainzFeedbackPayload: Decodable {
    let feedback: [ListenBrainzFeedbackItem]?
    let totalCount: Int?

    enum CodingKeys: String, CodingKey {
        case feedback
        case totalCount = "total_count"
    }
}

private struct ListenBrainzFeedbackItem: Decodable {
    let recordingMbid: String?
    let recordingMsid: String?
    let trackMetadata: ListenBrainzFeedbackTrack?

    enum CodingKeys: String, CodingKey {
        case recordingMbid = "recording_mbid"
        case recordingMsid = "recording_msid"
        case trackMetadata = "track_metadata"
    }
}

private struct ListenBrainzFeedbackTrack: Decodable {
    let trackName: String?
    let artistName: String?
    let releaseName: String?

    enum CodingKeys: String, CodingKey {
        case trackName = "track_name"
        case artistName = "artist_name"
        case releaseName = "release_name"
    }
}

private struct ListenBrainzFeedbackErrorPayload: Decodable {
    let error: String?
    let message: String?
}
