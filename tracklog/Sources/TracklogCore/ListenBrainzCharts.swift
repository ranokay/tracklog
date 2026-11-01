// swiftlint:disable cyclomatic_complexity function_parameter_count
import Foundation

// MARK: - ListenBrainz statistics

extension ListenBrainzAdapter: ChartServiceReading {
    public func top(
        _ type: ChartType,
        period: ChartPeriod,
        connection: Connection,
        credential: String,
        limit: Int,
    ) async throws -> ChartServicePage {
        guard let range = period.listenBrainzValue else {
            throw ServiceFailure.rejected("ListenBrainz has no chart for that period.")
        }
        let path = switch type {
        case .artists: "artists"
        case .albums: "releases"
        case .tracks: "recordings"
        }
        let request = try chartRequest(
            path: "stats/user/\(encodedAccount(connection.identity))/\(path)",
            query: [
                URLQueryItem(name: "range", value: range),
                URLQueryItem(name: "count", value: String(max(1, limit))),
                URLQueryItem(name: "offset", value: "0"),
            ],
            endpoint: connection.endpoint,
            credential: credential,
        )
        let response = try await ChartServiceHTTP.data(transport, request: request)
        switch response.statusCode {
        case 204:
            throw ChartServiceError.notReady
        case 200 ..< 300:
            let payload: ListenBrainzStatsPayload
            do {
                payload = try JSONDecoder().decode(ListenBrainzStatsPayload.self, from: response.body)
            } catch {
                throw ServiceFailure.retryable
            }
            guard let value = payload.payload else { throw ServiceFailure.retryable }
            let entries = try statsEntries(type: type, value: value)
            let returned = returnedRange(from: value)
            return ChartServicePage(
                items: Array(entries.prefix(max(1, limit))),
                returnedRange: returned,
            )
        case 401, 403:
            throw ServiceFailure.auth
        case 429:
            throw ServiceFailure.rateLimited(retryAfter: ChartServiceHTTP.retryAfter(from: response))
        case 400 ..< 500:
            throw ServiceFailure.rejected(Self.errorMessage(from: response))
        default:
            throw ServiceFailure.retryable
        }
    }

    public func allTimeAccountTotal(
        connection: Connection,
        credential: String,
    ) async throws -> Int {
        let request = try chartRequest(
            path: "user/\(encodedAccount(connection.identity))/listen-count",
            query: [],
            endpoint: connection.endpoint,
            credential: credential,
        )
        let response = try await ChartServiceHTTP.data(transport, request: request)
        switch response.statusCode {
        case 204:
            throw ChartServiceError.notReady
        case 200 ..< 300:
            guard let payload = try? JSONDecoder().decode(ListenBrainzCountPayload.self, from: response.body),
                  let count = payload.payload?.count
            else {
                throw ServiceFailure.retryable
            }
            return count
        case 401, 403:
            throw ServiceFailure.auth
        case 429:
            throw ServiceFailure.rateLimited(retryAfter: ChartServiceHTTP.retryAfter(from: response))
        case 400 ..< 500:
            throw ServiceFailure.rejected(Self.errorMessage(from: response))
        default:
            throw ServiceFailure.retryable
        }
    }

    private func chartRequest(
        path: String,
        query: [URLQueryItem],
        endpoint: ServiceEndpoint,
        credential: String,
    ) throws -> HTTPRequest {
        let token = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw ServiceFailure.rejected("Enter a user token.") }
        guard var components = URLComponents(string: "\(endpoint.description)/1/\(path)") else {
            throw ServiceFailure.rejected(nil)
        }
        if !query.isEmpty {
            components.queryItems = query
        }
        guard let url = components.url else { throw ServiceFailure.rejected(nil) }
        return HTTPRequest(
            method: .get,
            url: url,
            headers: [
                "Authorization": "Token \(token)",
                "User-Agent": userAgent,
                "Accept": "application/json",
            ],
        )
    }

    private func encodedAccount(_ value: String) throws -> String {
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

    private func statsEntries(
        type: ChartType,
        value: ListenBrainzStatsValue,
    ) throws -> [ChartItem] {
        switch type {
        case .artists:
            guard let rows = value.artists else { throw ServiceFailure.retryable }
            return rows.enumerated().compactMap { index, row in
                namedItem(
                    rank: index + 1,
                    type: .artists,
                    title: row.artistName,
                    subtitle: "",
                    count: row.listenCount,
                    providerID: row.artistMbid,
                )
            }
        case .albums:
            guard let rows = value.releases else { throw ServiceFailure.retryable }
            return rows.enumerated().compactMap { index, row in
                namedItem(
                    rank: index + 1,
                    type: .albums,
                    title: row.releaseName,
                    subtitle: row.artistName,
                    count: row.listenCount,
                    providerID: row.releaseMbid,
                )
            }
        case .tracks:
            guard let rows = value.recordings else { throw ServiceFailure.retryable }
            return rows.enumerated().compactMap { index, row in
                namedItem(
                    rank: index + 1,
                    type: .tracks,
                    title: row.trackName,
                    subtitle: row.artistName,
                    count: row.listenCount,
                    providerID: row.recordingMbid,
                )
            }
        }
    }

    private func namedItem(
        rank: Int,
        type: ChartType,
        title: String?,
        subtitle: String?,
        count: Int,
        providerID: String?,
    ) -> ChartItem? {
        let title = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty else { return nil }
        let subtitle = subtitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let provider = providerID?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ChartItem(
            rank: rank,
            title: title,
            subtitle: subtitle,
            count: count,
            identityKey: ChartIdentity.serviceKey(
                providerID: provider,
                type: type,
                title: title,
                subtitle: subtitle,
            ),
            providerID: provider?.isEmpty == true ? nil : provider,
            artworkHash: nil,
        )
    }

    private func returnedRange(from value: ListenBrainzStatsValue) -> ChartReturnedRange? {
        guard let start = value.fromTS, let end = value.toTS, start > 0, end > 0 else { return nil }
        let updated = value.lastUpdated.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
        return ChartReturnedRange(
            start: Date(timeIntervalSince1970: start),
            end: Date(timeIntervalSince1970: end),
            lastUpdated: updated,
        )
    }

    private static func errorMessage(from response: HTTPResponse) -> String? {
        guard let payload = try? JSONDecoder().decode(ListenBrainzErrorPayload.self, from: response.body) else {
            return nil
        }
        let text = payload.error ?? payload.message
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Payloads

private struct ListenBrainzStatsPayload: Decodable {
    let payload: ListenBrainzStatsValue?
}

private struct ListenBrainzStatsValue: Decodable {
    let artists: [ListenBrainzArtistRow]?
    let releases: [ListenBrainzReleaseRow]?
    let recordings: [ListenBrainzRecordingRow]?
    let fromTS: Double?
    let toTS: Double?
    let lastUpdated: Double?

    enum CodingKeys: String, CodingKey {
        case artists
        case releases
        case recordings
        case fromTS = "from_ts"
        case toTS = "to_ts"
        case lastUpdated = "last_updated"
    }
}

private struct ListenBrainzArtistRow: Decodable {
    let artistName: String?
    let artistMbid: String?
    let listenCount: Int

    enum CodingKeys: String, CodingKey {
        case artistName = "artist_name"
        case artistMbid = "artist_mbid"
        case listenCount = "listen_count"
    }
}

private struct ListenBrainzReleaseRow: Decodable {
    let releaseName: String?
    let releaseMbid: String?
    let artistName: String?
    let listenCount: Int

    enum CodingKeys: String, CodingKey {
        case releaseName = "release_name"
        case releaseMbid = "release_mbid"
        case artistName = "artist_name"
        case listenCount = "listen_count"
    }
}

private struct ListenBrainzRecordingRow: Decodable {
    let trackName: String?
    let recordingMbid: String?
    let artistName: String?
    let listenCount: Int

    enum CodingKeys: String, CodingKey {
        case trackName = "track_name"
        case recordingMbid = "recording_mbid"
        case artistName = "artist_name"
        case listenCount = "listen_count"
    }
}

private struct ListenBrainzCountPayload: Decodable {
    let payload: ListenBrainzCountValue?
}

private struct ListenBrainzCountValue: Decodable {
    let count: Int?
}

private struct ListenBrainzErrorPayload: Decodable {
    let error: String?
    let message: String?
}

// swiftlint:enable cyclomatic_complexity function_parameter_count
