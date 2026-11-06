// swiftlint:disable file_length
import Foundation

// MARK: - Identity

/// The three local entities a chart, History row, Loved row or palette row can
/// open. The kind is part of every override key because an artist and an album
/// can share a display name.
public enum EntityKind: String, CaseIterable, Codable, Sendable {
    case artist
    case album
    case track

    public var displayName: String {
        switch self {
        case .artist: "Artist"
        case .album: "Album"
        case .track: "Track"
        }
    }

    public var article: String {
        switch self {
        case .artist: "artist"
        case .album: "album"
        case .track: "track"
        }
    }

    /// Only an artist or album has a user-chosen image.
    public var supportsImageOverride: Bool {
        self != .track
    }
}

/// One detail page, named by the same local grouping key the local charts use.
/// `providerID` is a ListenBrainz MBID when the row supplied one.
public struct EntityRequest: Equatable, Sendable {
    public let kind: EntityKind
    public let key: String
    public let title: String
    public let subtitle: String
    public let providerID: String?
    /// The album of a track page, used by the local rows' subtitle.
    public let album: String

    public init(
        kind: EntityKind,
        key: String,
        title: String,
        subtitle: String = "",
        providerID: String? = nil,
        album: String = "",
    ) {
        self.kind = kind
        self.key = key
        self.title = title
        self.subtitle = subtitle
        self.providerID = providerID
        self.album = album
    }

    public static func artist(name: String, providerID: String? = nil) -> EntityRequest? {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let key = LocalArtistIdentity.key(name: title) else { return nil }
        return EntityRequest(kind: .artist, key: key, title: title, providerID: providerID)
    }

    public static func album(
        album: String,
        artist: String,
        providerID: String? = nil,
    ) -> EntityRequest? {
        let title = album.trimmingCharacters(in: .whitespacesAndNewlines)
        let subtitle = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let key = LocalAlbumIdentity.key(album: title, artist: subtitle) else { return nil }
        return EntityRequest(
            kind: .album,
            key: key,
            title: title,
            subtitle: subtitle,
            providerID: providerID,
        )
    }

    public static func track(
        title: String,
        artist: String,
        album: String = "",
        providerID: String? = nil,
    ) -> EntityRequest? {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let key = LocalTrackIdentity.key(title: title, artist: artist) else { return nil }
        return EntityRequest(
            kind: .track,
            key: key,
            title: title,
            subtitle: artist,
            providerID: providerID,
            album: album.trimmingCharacters(in: .whitespacesAndNewlines),
        )
    }

    public static func track(_ listen: Listen) -> EntityRequest? {
        track(
            title: listen.processed.title,
            artist: listen.processed.artist,
            album: listen.processed.album,
        )
    }

    /// An album's artist field is the album artist when the listen captured
    /// one, because that is the exact Albums chart grouping key.
    public static func album(from listen: Listen) -> EntityRequest? {
        let artist = listen.processed.albumArtist.trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
            ? listen.processed.artist
            : listen.processed.albumArtist
        return album(album: listen.processed.album, artist: artist)
    }

    public static func artist(from listen: Listen) -> EntityRequest? {
        artist(name: listen.processed.artist)
    }

    public static func chartItem(_ item: ChartItem, type: ChartType) -> EntityRequest? {
        switch type {
        case .artists:
            artist(name: item.title, providerID: item.providerID)
        case .albums:
            album(album: item.title, artist: item.subtitle, providerID: item.providerID)
        case .tracks:
            track(title: item.title, artist: item.subtitle, providerID: item.providerID)
        }
    }

    public static func catalogueRow(_ row: CatalogueRow) -> EntityRequest? {
        switch row.group {
        case .artists:
            artist(name: row.title)
        case .albums:
            album(album: row.title, artist: row.subtitle)
        case .tracks, .loved:
            track(title: row.title, artist: row.subtitle)
        }
    }

    public static func lovedRow(_ row: LovedRow) -> EntityRequest? {
        var providerID: String?
        if case let .mbid(value) = row.reference {
            providerID = value
        }
        return track(
            title: row.title,
            artist: row.artist,
            album: row.album,
            providerID: providerID,
        )
    }

    public var displaySubtitle: String {
        [subtitle, kind == .track ? album : ""]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " — ")
    }
}

// MARK: - Local section

/// The whole local history for one entity: the count, the two ends of the
/// range and, on an artist or album page, the top tracks inside it. The current
/// connection never changes any field.
public struct EntityLocalDetail: Equatable, Sendable {
    public let count: Int
    public let firstListenedAt: Date?
    public let lastListenedAt: Date?
    public let topTracks: [ChartItem]
    public let capturedArtworkHash: String?

    public init(
        count: Int = 0,
        firstListenedAt: Date? = nil,
        lastListenedAt: Date? = nil,
        topTracks: [ChartItem] = [],
        capturedArtworkHash: String? = nil,
    ) {
        self.count = count
        self.firstListenedAt = firstListenedAt
        self.lastListenedAt = lastListenedAt
        self.topTracks = topTracks
        self.capturedArtworkHash = capturedArtworkHash
    }
}

// MARK: - Service section

public struct EntityFact: Equatable, Sendable {
    public let label: String
    public let value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

/// What Last.fm's `getInfo` answered. Tags and wiki text deliberately have no
/// field here; they stay in #89.
public struct EntityServiceFacts: Equatable, Sendable {
    public let serviceName: String
    public let accountName: String
    public let facts: [EntityFact]
    public let link: URL?
    /// The album `getInfo` image. It is only fetched when precedence reaches
    /// it, and it is never persisted.
    public let artworkURL: URL?

    public init(
        serviceName: String,
        accountName: String,
        facts: [EntityFact],
        link: URL? = nil,
        artworkURL: URL? = nil,
    ) {
        self.serviceName = serviceName
        self.accountName = accountName
        self.facts = facts
        self.link = link
        self.artworkURL = artworkURL
    }
}

public enum EntityServiceFailure: Error, Equatable, Sendable {
    case appCredentials(AppCredentialProblem)
    case needsSignIn
    case rateLimited(retryAfter: TimeInterval?)
    /// The transport could not deliver the request. This is the only case
    /// that may say the service could not be reached.
    case offline
    case timedOut
    /// An answer arrived but its readable fields could not be interpreted, or
    /// the entity object carried no facts and no link.
    case unreadable
    /// The service answered with its own trouble: a 5xx, a temporary service
    /// code, or an HTTP status the transport refused.
    case serviceUnavailable
    /// The stored app credentials could not be read.
    case credentialsUnavailable
    /// A failure the entity mapping does not recognize.
    case unexpected
    case service(String?)

    public var needsSettings: Bool {
        if case .appCredentials = self {
            return true
        }
        return false
    }

    public var message: String {
        switch self {
        case let .appCredentials(problem):
            "\(problem.title). \(problem.detail)"
        case .needsSignIn:
            "Last.fm needs sign-in. Sign in on Services to see service details."
        case let .rateLimited(retryAfter):
            if let retryAfter, retryAfter > 0 {
                "Last.fm is rate limiting requests. Try again in \(Int(retryAfter.rounded(.up))) seconds."
            } else {
                "Last.fm is rate limiting requests. Try again shortly."
            }
        case .offline:
            "Last.fm could not be reached. Service details are unavailable."
        case .timedOut:
            "Last.fm took too long to answer. Service details are unavailable."
        case .unreadable:
            "Last.fm sent an answer this app could not read. Service details are unavailable."
        case .serviceUnavailable:
            "Last.fm is having trouble answering. Service details are unavailable."
        case .credentialsUnavailable:
            "Last.fm credentials could not be read. Service details are unavailable."
        case .unexpected:
            "Last.fm service details could not be loaded. Try again."
        case let .service(message):
            message ?? "Last.fm rejected the detail request."
        }
    }
}

public enum EntityServiceSection: Equatable, Sendable {
    case loading
    case facts(EntityServiceFacts)
    /// The entity does not exist on the service. This is not a read failure,
    /// so the page offers no retry.
    case missing(String)
    /// No Last.fm connection, or a service with no detail read.
    case unavailable(String)
    case failed(EntityServiceFailure)
}

/// The service half of the detail page. Last.fm implements it with
/// `getInfo`; the other services do not, so they publish the one-line reason.
public protocol EntityServiceReading: Sendable {
    var kind: ServiceKind { get }
    func entityDetails(
        _ request: EntityRequest,
        connection: Connection,
    ) async throws -> EntityServiceFacts
}

public enum EntityServiceCopy {
    public static func unavailable(connection: Connection?) -> String {
        guard let connection else {
            return "No connection is current. Connect Last.fm in Services to see service details."
        }
        switch connection.kind {
        case .lastFM:
            return "Last.fm service details are unavailable for this page."
        case .libreFM:
            return "Libre.fm has no detail read. Choose a Last.fm connection for service details."
        case .listenBrainz:
            return "ListenBrainz has no detail read. Choose a Last.fm connection for service details."
        }
    }

    public static func missing(kind: EntityKind, title: String) -> String {
        "Last.fm has no \(kind.article) details for “\(title)”."
    }

    public static func listenBrainzLink(kind: EntityKind, providerID: String?) -> URL? {
        guard let providerID = providerID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !providerID.isEmpty
        else { return nil }
        let route = switch kind {
        case .artist: "artist"
        case .album: "release"
        case .track: "recording"
        }
        return URL(string: "https://listenbrainz.org/\(route)/\(providerID)")
    }
}

// MARK: - Images

public enum EntityImageSource: Equatable, Sendable {
    case neutral
    case override
    case approximate
    case captured
    case service
}

/// The stored copy of one user-chosen artist or album image. Its key is the
/// local chart grouping key, so it is shared across connections and survives
/// unlink and listen deletion.
public struct ImageOverride: Equatable, Identifiable, Sendable {
    public let kind: EntityKind
    public let key: String
    public let title: String
    public let subtitle: String
    public let artworkHash: String
    public let updatedAt: Date

    public init(
        kind: EntityKind,
        key: String,
        title: String,
        subtitle: String = "",
        artworkHash: String,
        updatedAt: Date,
    ) {
        self.kind = kind
        self.key = key
        self.title = title
        self.subtitle = subtitle
        self.artworkHash = artworkHash
        self.updatedAt = updatedAt
    }

    public var id: String {
        "\(kind.rawValue)\u{1F}\(key)"
    }

    public var displayName: String {
        subtitle.isEmpty ? title : "\(title) — \(subtitle)"
    }
}

/// The entity the Images Settings page is currently choosing an image for.
/// It is transient: it is cleared when the page finishes or the droplet
/// deactivates.
public struct ImageOverrideDraft: Equatable, Sendable {
    public let kind: EntityKind
    public let key: String
    public let title: String
    public let subtitle: String

    public init(kind: EntityKind, key: String, title: String, subtitle: String = "") {
        self.kind = kind
        self.key = key
        self.title = title
        self.subtitle = subtitle
    }

    public init?(request: EntityRequest) {
        guard request.kind.supportsImageOverride else { return nil }
        self.init(
            kind: request.kind,
            key: request.key,
            title: request.title,
            subtitle: request.subtitle,
        )
    }

    public var displayName: String {
        subtitle.isEmpty ? title : "\(title) — \(subtitle)"
    }
}

public enum ImageOverridePolicy {
    /// A file larger than this is refused before it is read, so a mistaken
    /// selection never occupies the droplet's memory.
    public static let maximumSourceBytes = 20 * 1024 * 1024
    /// Remote artwork larger than this is refused before it is decoded.
    public static let maximumRemoteBytes = 5 * 1024 * 1024
}

// MARK: - Detail page

public struct EntityDetail: Equatable, Sendable {
    public let request: EntityRequest
    public var local: EntityLocalDetail
    public var isLoadingLocal: Bool
    public var localFailure: CaptureFailure?
    public var service: EntityServiceSection
    /// A track page composes the existing TrackHistory value and paging as its
    /// local section. It is nil on artist and album pages.
    public var track: TrackHistory?
    public var imageData: Data?
    public var imageSource: EntityImageSource
    /// The hash the detail page can remove, when the user has an override.
    public var overrideHash: String?
    /// Set when the override exists but its stored copy cannot be read. The
    /// page falls back to the next source or neutral and Settings still offers
    /// replace/remove.
    public var overrideIsUnreadable: Bool

    public init(
        request: EntityRequest,
        local: EntityLocalDetail = EntityLocalDetail(),
        isLoadingLocal: Bool = true,
        localFailure: CaptureFailure? = nil,
        service: EntityServiceSection = .loading,
        track: TrackHistory? = nil,
        imageData: Data? = nil,
        imageSource: EntityImageSource = .neutral,
        overrideHash: String? = nil,
        overrideIsUnreadable: Bool = false,
    ) {
        self.request = request
        self.local = local
        self.isLoadingLocal = isLoadingLocal
        self.localFailure = localFailure
        self.service = service
        self.track = track
        self.imageData = imageData
        self.imageSource = imageSource
        self.overrideHash = overrideHash
        self.overrideIsUnreadable = overrideIsUnreadable
    }

    public var title: String {
        request.title
    }

    public var subtitle: String {
        request.displaySubtitle
    }

    public var isApproximateImage: Bool {
        imageSource == .approximate
    }

    public var canChangeImage: Bool {
        request.kind.supportsImageOverride
    }

    public var canRemoveImage: Bool {
        request.kind.supportsImageOverride && overrideHash != nil
    }
}

// MARK: - Copy

public enum EntityDetailCopy {
    public static func localCount(_ count: Int) -> String {
        "\(count.formatted()) \(count == 1 ? "listen" : "listens")"
    }

    public static func firstListen(_ date: Date) -> String {
        "First listened \(date.formatted(date: .long, time: .omitted))"
    }

    public static func lastListen(_ date: Date) -> String {
        "Last listened \(date.formatted(date: .long, time: .omitted))"
    }

    public static func emptyLocal(kind: EntityKind) -> String {
        "No local listens for this \(kind.article)."
    }

    public static func topTracksTitle(kind: EntityKind) -> String {
        "Top \(kind == .artist ? "tracks" : "album tracks")"
    }
}
