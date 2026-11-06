import Foundation

/// One album result from the iTunes Search API. Only the fields the exact-match
/// rule needs are kept.
public struct ArtistImageAlbum: Equatable, Sendable {
    public let artistID: String
    public let artistName: String
    public let artworkURL: URL?

    public init(artistID: String, artistName: String, artworkURL: URL?) {
        self.artistID = artistID
        self.artistName = artistName
        self.artworkURL = artworkURL
    }
}

/// The search seam. Production uses the iTunes Search API; tests and the
/// harness script the same port.
public protocol ArtistImageSearching: Sendable {
    func albums(forArtist name: String, limit: Int) async throws -> [ArtistImageAlbum]
}

/// The download seam for remote artwork. It never receives a credential: the
/// only headers are a user agent and an image accept header.
public protocol RemoteImageLoading: Sendable {
    func imageData(at url: URL) async throws -> Data
}

public enum ArtistImageError: Error, Equatable, Sendable {
    case insecureURL
    case badStatus(Int)
    case oversized
    case unreadable
}

/// The approximate artist image's matching rule and cache lifetimes. The rule
/// is exact after normalising; there is no fuzzy fallback.
public enum ArtistImageLookup {
    /// "Top results" is the first ten album results. `attribute=artistTerm`
    /// keeps album titles from filling the answer with other artists.
    public static let searchLimit = 10
    public static let hitLifetime: TimeInterval = 30 * 24 * 60 * 60
    public static let missLifetime: TimeInterval = 24 * 60 * 60
    /// The artist page's circle is 84 points, so the search API's 100-pixel
    /// thumbnail is not enough on a Retina display. iTunes serves any size in
    /// the artwork file name; the store caps the stored copy at 512 pixels.
    public static let requestedArtworkSize = 600

    /// A cache key scoped to the requested size, so a thumbnail stored by an
    /// older build is not reused after the request grows.
    public static func cacheKey(forArtist key: String) -> String {
        "\(key)\u{1F}\(requestedArtworkSize)"
    }

    public enum Resolution: Equatable, Sendable {
        case image(URL)
        case noMatch
        case ambiguous
        case noArtwork
    }

    public static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The first result whose artist name matches exactly after normalising.
    /// Two different artist IDs under that name mean the answer cannot say
    /// which artist was meant, so the caller uses the neutral sleeve.
    public static func resolve(
        _ albums: [ArtistImageAlbum],
        artist: String,
    ) -> Resolution {
        let wanted = normalize(artist)
        let matches = albums.filter { normalize($0.artistName) == wanted }
        guard !matches.isEmpty else { return .noMatch }
        let artistIDs = Set(matches.map(\.artistID).filter { !$0.isEmpty })
        if artistIDs.count > 1 {
            return .ambiguous
        }
        guard let artworkURL = matches[0].artworkURL else {
            return .noArtwork
        }
        return .image(artworkURL)
    }
}

public enum ArtistImageCacheOutcome: String, Equatable, Sendable {
    case hit
    case miss
}

/// One remembered lookup. A hit lasts 30 days; a definite miss, including
/// ambiguity and a match without artwork, lasts a day. A failed lookup writes
/// no row at all and retries on the next open.
public struct ArtistImageCacheEntry: Equatable, Sendable {
    public let artistKey: String
    public let artworkHash: String?
    public let outcome: ArtistImageCacheOutcome
    public let checkedAt: Date

    public init(
        artistKey: String,
        artworkHash: String?,
        outcome: ArtistImageCacheOutcome,
        checkedAt: Date,
    ) {
        self.artistKey = artistKey
        self.artworkHash = artworkHash
        self.outcome = outcome
        self.checkedAt = checkedAt
    }

    public func isFresh(now: Date) -> Bool {
        let lifetime = outcome == .hit ? ArtistImageLookup.hitLifetime : ArtistImageLookup.missLifetime
        return now.timeIntervalSince(checkedAt) < lifetime
    }
}

// MARK: - iTunes Search

/// The real iTunes Search client. It asks only for albums, restricts the
/// search to artist names, and returns the fields the exact-match rule needs.
public struct ITunesSearchClient: ArtistImageSearching {
    public static let endpoint = "https://itunes.apple.com/search"

    private let transport: any HTTPTransport
    private let userAgent: String

    public init(
        transport: any HTTPTransport,
        userAgent: String = TracklogHTTP.userAgent,
    ) {
        self.transport = transport
        self.userAgent = userAgent
    }

    public func albums(forArtist name: String, limit: Int) async throws -> [ArtistImageAlbum] {
        let artist = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !artist.isEmpty else { return [] }
        var components = URLComponents(string: Self.endpoint)
        components?.queryItems = [
            URLQueryItem(name: "term", value: artist),
            URLQueryItem(name: "entity", value: "album"),
            URLQueryItem(name: "attribute", value: "artistTerm"),
            URLQueryItem(name: "limit", value: String(max(1, min(limit, 200)))),
        ]
        guard let url = components?.url, url.scheme == "https" else {
            throw ArtistImageError.unreadable
        }
        let request = HTTPRequest(
            method: .get,
            url: url,
            headers: [
                "User-Agent": userAgent,
                "Accept": "application/json",
            ],
        )
        let response = try await transport.send(request)
        guard (200 ..< 300).contains(response.statusCode) else {
            throw ArtistImageError.badStatus(response.statusCode)
        }
        guard response.body.count <= ImageOverridePolicy.maximumRemoteBytes else {
            throw ArtistImageError.oversized
        }
        guard let payload = try? JSONDecoder().decode(SearchPayload.self, from: response.body) else {
            throw ArtistImageError.unreadable
        }
        return payload.results.compactMap { result in
            let artistName = result.artistName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !artistName.isEmpty else { return nil }
            let artwork = result.artworkUrl100.flatMap { Self.artworkURL(from: $0) }
            return ArtistImageAlbum(
                artistID: result.artistId.map(String.init) ?? "",
                artistName: artistName,
                artworkURL: artwork,
            )
        }
    }

    /// The search API answers with a `100x100bb` thumbnail. Replace the size
    /// segment so the download is large enough for the artist page; a URL
    /// without one is left alone.
    private static func artworkURL(from thumbnail: String) -> URL? {
        let size = ArtistImageLookup.requestedArtworkSize
        let scaled = thumbnail.replacingOccurrences(
            of: #"\d+x\d+bb"#,
            with: "\(size)x\(size)bb",
            options: .regularExpression,
        )
        return URL(string: scaled)
    }

    private struct SearchPayload: Decodable {
        let results: [SearchResult]
    }

    private struct SearchResult: Decodable {
        let artistId: Int?
        let artistName: String?
        let artworkUrl100: String?
    }
}

// MARK: - Remote image loading

/// The one guarded remote-image fetch. HTTPS only, no credentials, and a hard
/// response-size limit before anything is decoded.
public struct HTTPRemoteImageLoader: RemoteImageLoading {
    private let transport: any HTTPTransport
    private let userAgent: String

    public init(
        transport: any HTTPTransport,
        userAgent: String = TracklogHTTP.userAgent,
    ) {
        self.transport = transport
        self.userAgent = userAgent
    }

    public func imageData(at url: URL) async throws -> Data {
        guard url.scheme?.lowercased() == "https" else {
            throw ArtistImageError.insecureURL
        }
        let request = HTTPRequest(
            method: .get,
            url: url,
            headers: [
                "User-Agent": userAgent,
                "Accept": "image/*",
            ],
        )
        let response: HTTPResponse
        do {
            response = try await transport.send(
                request,
                bodyLimit: ImageOverridePolicy.maximumRemoteBytes,
            )
        } catch HTTPTransportError.bodyTooLarge {
            throw ArtistImageError.oversized
        }
        guard (200 ..< 300).contains(response.statusCode) else {
            throw ArtistImageError.badStatus(response.statusCode)
        }
        guard response.body.count <= ImageOverridePolicy.maximumRemoteBytes else {
            throw ArtistImageError.oversized
        }
        guard !response.body.isEmpty else {
            throw ArtistImageError.unreadable
        }
        return response.body
    }
}
