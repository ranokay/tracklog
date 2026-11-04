import Foundation

// MARK: - Last.fm catalogue reads

public extension LastFMClient {
    /// `artist.search`, `album.search` and `track.search`. These reads need
    /// only the application pair: no listener session key is attached.
    func search(_ group: CatalogueGroupKind, query: String, limit: Int) async throws -> CataloguePage {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw LastFMError.service(code: 6, message: "A search query is required.")
        }
        let clamped = max(1, limit)
        switch group {
        case .artists:
            return try await searchArtists(value, limit: clamped)
        case .albums:
            return try await searchAlbums(value, limit: clamped)
        case .tracks:
            return try await searchTracks(value, limit: clamped)
        case .loved:
            throw LastFMError.service(code: 6, message: "Loved tracks are read from an account.")
        }
    }

    /// `user.getLovedTracks` for one page. The account's identity is public;
    /// this read needs the app pair, not the listener's session key.
    func lovedTracks(account: String, page: Int, limit: Int) async throws -> CataloguePage {
        let read = try await lovedEntries(account: account, page: page, limit: limit)
        let rows = read.entries.compactMap { entry -> CatalogueRow? in
            guard let title = trimmed(entry.name), !title.isEmpty else { return nil }
            let artist = trimmed(entry.artist?.name) ?? ""
            return CatalogueRow(
                group: .loved,
                title: title,
                subtitle: artist,
                playbackQuery: CatalogueQuery.track(artist: artist, title: title),
                pageURL: CatalogueURL.httpsURL(from: entry.url),
            )
        }
        let hasMore = read.totalPages.map { read.currentPage < $0 }
            ?? (read.entries.count >= limit)
        return CataloguePage(rows: Array(rows.prefix(limit)), hasMore: hasMore)
    }

    /// The current connection's loved page for the Loved section. Rows the
    /// service could not name are counted, never guessed. The next cursor is
    /// the page after this one when the service reports another page.
    func lovedPage(
        connection: Connection,
        cursor: LovedCursor,
        limit: Int,
    ) async throws -> LovedServicePage {
        guard case let .page(page) = cursor else {
            throw LastFMError.service(code: 6, message: "Loved tracks are read by page.")
        }
        let read = try await lovedEntries(account: connection.identity, page: page, limit: limit)
        var omitted = 0
        let rows = read.entries.compactMap { entry -> LovedRow? in
            guard let title = trimmed(entry.name), !title.isEmpty,
                  let artist = trimmed(entry.artist?.name), !artist.isEmpty
            else {
                omitted += 1
                return nil
            }
            let providerID = trimmed(entry.mbid) ?? ""
            let id = providerID.isEmpty
                ? "\(dialect.rawValue):track:\(Identity.joined([title, artist]))"
                : "\(dialect.rawValue):mbid:\(providerID)"
            return LovedRow(
                connectionID: connection.id,
                id: id,
                title: title,
                artist: artist,
            )
        }
        let nextCursor: LovedCursor? = if let totalPages = read.totalPages {
            read.currentPage < totalPages ? .page(read.currentPage + 1) : nil
        } else {
            read.entries.count >= limit ? .page(read.currentPage + 1) : nil
        }
        return LovedServicePage(
            rows: Array(rows.prefix(limit)),
            omitted: omitted,
            nextCursor: nextCursor,
        )
    }

    private struct LovedEntriesRead {
        let entries: [LastFMLovedTrackValue]
        let currentPage: Int
        let totalPages: Int?
    }

    private func lovedEntries(
        account: String,
        page: Int,
        limit: Int,
    ) async throws -> LovedEntriesRead {
        let user = account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty else {
            throw LastFMError.service(code: 6, message: "A Last.fm account is required.")
        }
        let data = try await perform(
            method: "user.getlovedtracks",
            parameters: [
                "user": user,
                "page": String(max(1, page)),
                "limit": String(max(1, limit)),
            ],
        )
        guard let payload = try? JSONDecoder().decode(LastFMLovedTracksPayload.self, from: data),
              let loved = payload.lovedtracks
        else { throw LastFMError.malformedResponse }
        return LovedEntriesRead(
            entries: loved.track?.items ?? [],
            currentPage: loved.attr?.page?.value ?? page,
            totalPages: loved.attr?.totalPages?.value,
        )
    }

    private func searchArtists(_ query: String, limit: Int) async throws -> CataloguePage {
        let data = try await perform(
            method: "artist.search",
            parameters: ["artist": query, "limit": String(limit)],
        )
        guard let payload = try? JSONDecoder().decode(LastFMArtistSearchPayload.self, from: data)
        else { throw LastFMError.malformedResponse }
        let rows = (payload.results?.artistmatches?.artist?.items ?? []).compactMap { entry -> CatalogueRow? in
            guard let title = trimmed(entry.name), !title.isEmpty else { return nil }
            return CatalogueRow(
                group: .artists,
                title: title,
                subtitle: "",
                playbackQuery: CatalogueQuery.artist(title),
                pageURL: CatalogueURL.httpsURL(from: entry.url),
            )
        }
        return CataloguePage(rows: Array(rows.prefix(limit)), hasMore: rows.count > limit)
    }

    private func searchAlbums(_ query: String, limit: Int) async throws -> CataloguePage {
        let data = try await perform(
            method: "album.search",
            parameters: ["album": query, "limit": String(limit)],
        )
        guard let payload = try? JSONDecoder().decode(LastFMAlbumSearchPayload.self, from: data)
        else { throw LastFMError.malformedResponse }
        let rows = (payload.results?.albummatches?.album?.items ?? []).compactMap { entry -> CatalogueRow? in
            guard let title = trimmed(entry.name), !title.isEmpty else { return nil }
            let artist = trimmed(entry.artist) ?? ""
            return CatalogueRow(
                group: .albums,
                title: title,
                subtitle: artist,
                playbackQuery: CatalogueQuery.album(artist: artist, album: title),
                pageURL: CatalogueURL.httpsURL(from: entry.url),
            )
        }
        return CataloguePage(rows: Array(rows.prefix(limit)), hasMore: rows.count > limit)
    }

    private func searchTracks(_ query: String, limit: Int) async throws -> CataloguePage {
        let data = try await perform(
            method: "track.search",
            parameters: ["track": query, "limit": String(limit)],
        )
        guard let payload = try? JSONDecoder().decode(LastFMTrackSearchPayload.self, from: data)
        else { throw LastFMError.malformedResponse }
        let rows = (payload.results?.trackmatches?.track?.items ?? []).compactMap { entry -> CatalogueRow? in
            guard let title = trimmed(entry.name), !title.isEmpty else { return nil }
            let artist = trimmed(entry.artist) ?? ""
            return CatalogueRow(
                group: .tracks,
                title: title,
                subtitle: artist,
                playbackQuery: CatalogueQuery.track(artist: artist, title: title),
                pageURL: CatalogueURL.httpsURL(from: entry.url),
            )
        }
        return CataloguePage(rows: Array(rows.prefix(limit)), hasMore: rows.count > limit)
    }

    private func trimmed(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Service-supplied links are opened only when they normalise to a real https
/// address. A row whose link fails this check has no Last.fm action.
enum CatalogueURL {
    static func httpsURL(from raw: String?) -> URL? {
        guard let raw else { return nil }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, var components = URLComponents(string: text) else { return nil }
        if let scheme = components.scheme?.lowercased() {
            guard scheme == "http" || scheme == "https" else { return nil }
            components.scheme = "https"
        } else {
            guard let prefixed = URLComponents(string: "https://" + text) else { return nil }
            components = prefixed
        }
        guard components.scheme?.lowercased() == "https",
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              let url = components.url
        else { return nil }
        return url
    }
}

// MARK: - Adapter

extension LastFMAdapter: CatalogueSearching {
    public func search(
        _ group: CatalogueGroupKind,
        query: String,
        limit: Int,
    ) async throws -> CataloguePage {
        do {
            return try await client.search(group, query: query, limit: limit)
        } catch {
            throw Self.catalogueFailure(for: error)
        }
    }

    public func lovedTracks(
        account: String,
        page: Int,
        limit: Int,
    ) async throws -> CataloguePage {
        do {
            return try await client.lovedTracks(account: account, page: page, limit: limit)
        } catch {
            throw Self.catalogueFailure(for: error)
        }
    }

    private static func catalogueFailure(for error: any Error) -> ServiceFailure {
        if let failure = error as? ServiceFailure {
            return failure
        }
        return (error as? LastFMError)?.serviceFailure ?? .retryable
    }
}

extension LastFMAdapter: LovedServiceReading {
    public var firstCursor: LovedCursor {
        .page(1)
    }

    public func loved(
        connection: Connection,
        credential _: String,
        cursor: LovedCursor,
        limit: Int,
    ) async throws -> LovedServicePage {
        do {
            return try await client.lovedPage(
                connection: connection,
                cursor: cursor,
                limit: limit,
            )
        } catch {
            throw Self.catalogueFailure(for: error)
        }
    }
}
