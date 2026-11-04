import Foundation

// MARK: - Date jump

/// Where a date jump puts the top of History.
public enum HistoryPosition: Equatable, Sendable {
    /// No listen starts at or after the requested instant, so the newest page.
    case newest
    /// The last stored listen at the earliest start instant at or after the
    /// request. A page ending at this cursor includes every listen that
    /// started at that instant and all older rows.
    case atCursor(ListenCursor)

    public var cursor: ListenCursor? {
        switch self {
        case .newest:
            nil
        case let .atCursor(cursor):
            cursor
        }
    }
}

/// Why the History feed is positioned away from its newest row.
public struct HistoryJumpNotice: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// The requested day has listens; the window starts at one of them.
        case positioned
        /// The requested local day has no listens, but a later listen exists.
        case emptyDay
        /// The request is newer than every stored listen.
        case afterNewest
    }

    public let requestedAt: Date
    public let kind: Kind

    public init(requestedAt: Date, kind: Kind) {
        self.requestedAt = requestedAt
        self.kind = kind
    }
}

/// The reads History navigation needs beyond the feed: date positioning and
/// paging in both directions. Kept apart from ``ListenStore`` so a store that
/// only feeds History remains a ``ListenStore``.
public protocol HistoryNavigationStore: Sendable {
    /// The position for a date jump, independent of the loaded page.
    func historyPosition(at date: Date) async throws -> HistoryPosition
    /// A page ending at `cursor` inclusive, newest first. Used by a jump and by
    /// reloading the same window after a capture.
    func page(limit: Int, endingAt cursor: ListenCursor) async throws -> [Listen]
    /// The immediately newer page after `cursor`, newest first. Used to walk a
    /// jumped window back toward the live top.
    func page(limit: Int, after cursor: ListenCursor) async throws -> [Listen]
    /// Whether any stored listen is strictly older than `cursor`.
    func hasOlderListen(than cursor: ListenCursor) async throws -> Bool
    /// Whether any stored listen is strictly newer than `cursor`.
    func hasNewerListen(than cursor: ListenCursor) async throws -> Bool
}

// MARK: - Track history

/// One track's full local count and first listen, computed over the whole
/// database rather than the loaded History page.
public struct TrackHistorySummary: Equatable, Sendable {
    public let count: Int
    public let firstListenedAt: Date?

    public init(count: Int, firstListenedAt: Date?) {
        self.count = count
        self.firstListenedAt = firstListenedAt
    }
}

/// Reads one track's history. SQLite implements it on the dedicated read-only
/// connection, filtering by ``LocalTrackIdentity/key(title:artist:)`` in Swift
/// so a large history never occupies the writer actor or blocks capture.
public protocol TrackHistoryStore: Sendable {
    /// The full count and earliest listen for `key`.
    func trackHistorySummary(matching key: String) async throws -> TrackHistorySummary
    /// One page of that track, newest first. Stops at `limit` matching rows.
    func trackHistoryPage(
        matching key: String,
        limit: Int,
        before cursor: ListenCursor?,
    ) async throws -> [Listen]
}

/// The track view's snapshot. It updates when the view is opened again or
/// explicitly reloaded, not on every capture, so capture never waits for it.
public struct TrackHistory: Equatable, Sendable {
    public let identityKey: String
    public let title: String
    public let artist: String
    public let album: String
    public internal(set) var listens: [Listen]
    public internal(set) var totalCount: Int
    public internal(set) var firstListenedAt: Date?
    public internal(set) var hasMore: Bool
    public internal(set) var isLoading: Bool
    public internal(set) var failure: CaptureFailure?

    public init(
        identityKey: String,
        title: String,
        artist: String,
        album: String,
        listens: [Listen] = [],
        totalCount: Int = 0,
        firstListenedAt: Date? = nil,
        hasMore: Bool = false,
        isLoading: Bool = true,
        failure: CaptureFailure? = nil,
    ) {
        self.identityKey = identityKey
        self.title = title
        self.artist = artist
        self.album = album
        self.listens = listens
        self.totalCount = totalCount
        self.firstListenedAt = firstListenedAt
        self.hasMore = hasMore
        self.isLoading = isLoading
        self.failure = failure
    }

    /// Header metadata, without the album when it is empty.
    public var subtitle: String {
        [artist, album]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " — ")
    }
}
