import Foundation

/// The four catalogue groups the palette shows, in display order.
public enum CatalogueGroupKind: String, CaseIterable, Identifiable, Sendable {
    case artists
    case albums
    case tracks
    case loved

    public var id: String {
        rawValue
    }

    public var title: String {
        switch self {
        case .artists: "Artists"
        case .albums: "Albums"
        case .tracks: "Tracks"
        case .loved: "Loved"
        }
    }
}

/// One row the palette can show. `playbackQuery` is the artist name, the
/// artist's album name, or the artist's track title, never a URL.
public struct CatalogueRow: Identifiable, Equatable, Sendable {
    public let group: CatalogueGroupKind
    public let title: String
    public let subtitle: String
    public let playbackQuery: String
    /// A valid https page, or nil when the service supplied none. A row with
    /// no page offers no Last.fm action.
    public let pageURL: URL?

    public init(
        group: CatalogueGroupKind,
        title: String,
        subtitle: String,
        playbackQuery: String,
        pageURL: URL?,
    ) {
        self.group = group
        self.title = title
        self.subtitle = subtitle
        self.playbackQuery = playbackQuery
        self.pageURL = pageURL
    }

    public var id: String {
        [group.rawValue, title, subtitle, playbackQuery, pageURL?.absoluteString ?? ""]
            .joined(separator: "\u{1F}")
    }
}

/// One page from the catalogue port. `hasMore` means the service reported
/// another page after this one.
public struct CataloguePage: Equatable, Sendable {
    public let rows: [CatalogueRow]
    public let hasMore: Bool

    public init(rows: [CatalogueRow], hasMore: Bool) {
        self.rows = rows
        self.hasMore = hasMore
    }
}

/// The real adapter implements this with signed-only-by-app-key Last.fm
/// requests. Search and loved reads need no user session.
public protocol CatalogueSearching: Sendable {
    func search(_ group: CatalogueGroupKind, query: String, limit: Int) async throws -> CataloguePage
    func lovedTracks(account: String, page: Int, limit: Int) async throws -> CataloguePage
}

/// Why one group could not answer. Each group carries its own failure, so one
/// broken service call never replaces the other groups' results.
public enum CatalogueSearchFailure: Error, Equatable, Sendable {
    /// Last.fm rejected the app's own credentials. The remedy is Settings,
    /// never a listener sign-in.
    case appCredentials(AppCredentialProblem)
    case timedOut
    case offline
    case rateLimited(TimeInterval?)
    case service(String)

    public var message: String {
        switch self {
        case let .appCredentials(problem):
            problem.title
        case .timedOut:
            "Last.fm took too long to answer."
        case .offline:
            "The Last.fm catalogue could not be reached."
        case .rateLimited:
            "Last.fm is rate limiting searches. Try again shortly."
        case let .service(message):
            message
        }
    }

    public var needsSettings: Bool {
        if case .appCredentials = self {
            return true
        }
        return false
    }

    public var appCredentialProblem: AppCredentialProblem? {
        guard case let .appCredentials(problem) = self else { return nil }
        return problem
    }
}

public enum CatalogueGroupPhase: Equatable, Sendable {
    case idle
    case loading
    case ready
    case empty
    case unavailable
    case failed(CatalogueSearchFailure)
}

public struct CatalogueGroupState: Identifiable, Equatable, Sendable {
    public let kind: CatalogueGroupKind
    public var phase: CatalogueGroupPhase = .idle
    public var rows: [CatalogueRow] = []
    /// The account for Loved, or the reason it is unavailable, or a bounded
    /// read note.
    public var detail: String?

    public init(kind: CatalogueGroupKind) {
        self.kind = kind
    }

    public var id: CatalogueGroupKind {
        kind
    }
}

/// The palette's published search state. Nothing here is cached or persisted:
/// a new session starts idle and every query is a new read.
public struct CatalogueSearchState: Equatable, Sendable {
    public var query = ""
    public var isWaiting = false
    public var isSearching = false
    public var hasSearched = false
    public var groups: [CatalogueGroupState] = CatalogueGroupKind.allCases.map(CatalogueGroupState.init)

    public init() {}

    public func group(_ kind: CatalogueGroupKind) -> CatalogueGroupState? {
        groups.first { $0.kind == kind }
    }

    public var appCredentialProblem: AppCredentialProblem? {
        for group in groups {
            if case let .failed(failure) = group.phase,
               let problem = failure.appCredentialProblem {
                return problem
            }
        }
        return nil
    }

    public var resultCount: Int {
        groups.reduce(0) { $0 + $1.rows.count }
    }
}

/// The one query shape used by every play action, so the palette, History,
/// charts and the strip cannot drift apart.
public enum CatalogueQuery {
    public static func artist(_ name: String) -> String {
        combined(name)
    }

    public static func album(artist: String, album: String) -> String {
        combined(artist, album)
    }

    public static func track(artist: String, title: String) -> String {
        combined(artist, title)
    }

    public static func combined(_ values: String...) -> String {
        values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
