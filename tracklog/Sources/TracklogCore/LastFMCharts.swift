// swiftlint:disable cyclomatic_complexity
import Foundation

// MARK: - Last.fm reads

public extension LastFMClient {
    /// `user.getTopArtists`, `user.getTopAlbums` or `user.getTopTracks` for
    /// the connection's own account. Last.fm exposes rolling periods only; the
    /// returned page therefore carries no returned span.
    func topChart(
        type: ChartType,
        user: String,
        period: ChartPeriod,
        limit: Int,
    ) async throws -> ChartServicePage {
        guard let value = period.lastFMValue else {
            throw LastFMError.service(code: 6, message: "Last.fm has no chart for that period.")
        }
        let name = user.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw LastFMError.service(code: 6, message: "A Last.fm account is required.")
        }
        let method = switch type {
        case .artists: "user.getTopArtists"
        case .albums: "user.getTopAlbums"
        case .tracks: "user.getTopTracks"
        }
        let data = try await perform(
            method: method,
            parameters: [
                "user": name,
                "period": value,
                "limit": String(max(1, limit)),
            ],
        )

        let entries: [LastFMChartEntry]
        switch type {
        case .artists:
            guard let items = try? JSONDecoder().decode(LastFMTopArtistsPayload.self, from: data)
                .topartists?.artist?.entries
            else { throw LastFMError.malformedResponse }
            entries = items
        case .albums:
            guard let items = try? JSONDecoder().decode(LastFMTopAlbumsPayload.self, from: data)
                .topalbums?.album?.entries
            else { throw LastFMError.malformedResponse }
            entries = items
        case .tracks:
            guard let items = try? JSONDecoder().decode(LastFMTopTracksPayload.self, from: data)
                .toptracks?.track?.entries
            else { throw LastFMError.malformedResponse }
            entries = items
        }

        let rows = try entries.enumerated().compactMap { index, entry -> ChartItem? in
            let title = entry.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !title.isEmpty else { return nil }
            guard let count = entry.playcount?.value else {
                throw LastFMError.malformedResponse
            }
            let subtitle: String = switch type {
            case .artists:
                ""
            case .albums, .tracks:
                entry.artist?.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            }
            let providerID = entry.mbid?.trimmingCharacters(in: .whitespacesAndNewlines)
            return ChartItem(
                rank: entry.attr?.rank?.value ?? index + 1,
                title: title,
                subtitle: subtitle,
                count: count,
                identityKey: ChartIdentity.serviceKey(
                    providerID: providerID,
                    type: type,
                    title: title,
                    subtitle: subtitle,
                ),
                providerID: providerID?.isEmpty == true ? nil : providerID,
                artworkHash: nil,
            )
        }
        return ChartServicePage(items: Array(rows.prefix(max(1, limit))), returnedRange: nil)
    }

    /// The lifetime playcount `user.getInfo` reports. This is an account
    /// total, not the sum of a ranked page.
    func accountPlaycount(user: String) async throws -> Int {
        let name = user.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw LastFMError.service(code: 6, message: "A Last.fm account is required.")
        }
        let data = try await perform(method: "user.getInfo", parameters: ["user": name])
        guard let payload = try? JSONDecoder().decode(UserPayload.self, from: data),
              let text = payload.user?.playcount?.trimmingCharacters(in: .whitespacesAndNewlines),
              let count = Int(text)
        else {
            throw LastFMError.malformedResponse
        }
        return count
    }
}

// MARK: - Adapter

extension LastFMAdapter: ChartServiceReading {
    public func top(
        _ type: ChartType,
        period: ChartPeriod,
        connection: Connection,
        credential _: String,
        limit: Int,
    ) async throws -> ChartServicePage {
        do {
            return try await client.topChart(
                type: type,
                user: connection.identity,
                period: period,
                limit: limit,
            )
        } catch {
            throw Self.chartFailure(for: error)
        }
    }

    public func allTimeAccountTotal(
        connection: Connection,
        credential _: String,
    ) async throws -> Int {
        do {
            return try await client.accountPlaycount(user: connection.identity)
        } catch {
            throw Self.chartFailure(for: error)
        }
    }

    private static func chartFailure(for error: any Error) -> ServiceFailure {
        if let failure = error as? ServiceFailure {
            return failure
        }
        return (error as? LastFMError)?.serviceFailure ?? .retryable
    }
}

// swiftlint:enable cyclomatic_complexity
