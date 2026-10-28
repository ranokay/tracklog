import Combine
import Foundation

/// The one observable app state the droplet's views read.
@MainActor
public final class TracklogAppState: ObservableObject {
    @Published public internal(set) var scrobblingEnabled = false
    /// Whether now playing is sent. Capture keeps running when this is off.
    @Published public internal(set) var nowPlayingEnabled = true
    /// End of the current pause, or `nil` when capture is not paused.
    @Published public internal(set) var pausedUntil: Date?
    /// The engine's threshold floor, in seconds.
    @Published public internal(set) var minimumDuration = CaptureSettings.defaultMinimumDuration
    /// Every player the feed has seen, in first-seen order.
    @Published public internal(set) var seenApps: [SeenApp] = []
    /// Saved simple edits, in the order the metadata pipeline applies them.
    @Published public internal(set) var simpleEdits: [SimpleEditRule] = []
    /// Every linked service, in link order.
    @Published public internal(set) var connections: [Connection] = []
    /// The read cursor. It never scopes local history or redirects a delivery.
    @Published public internal(set) var currentConnectionID: Int64?
    /// Set until a connection read succeeds, so the Services page can say the
    /// list is unavailable rather than empty.
    @Published public internal(set) var connectionsFailure: CaptureFailure?
    /// Saved blocks, in the order the metadata pipeline evaluates them.
    @Published public internal(set) var blocks: [BlockRule] = []
    /// Set until a block read succeeds, even if a later storage failure
    /// replaces the general `failure` shown in diagnostics.
    @Published public internal(set) var blocksFailure: CaptureFailure?
    @Published public internal(set) var nowPlaying: MediaSample?
    @Published public internal(set) var status: ScrobbleStatus = .idle
    /// A pending request to open the Edits page with a new rule pre-filled
    /// from the current listen's fields as the metadata pipeline matches
    /// them.
    @Published public internal(set) var editPrefill: EditPrefill?
    /// Whether any media source can deliver a sample. Derived from the live
    /// status so the two cannot drift apart.
    public var feedAvailable: Bool {
        mediaStatus.isAvailable
    }

    /// The connection service-backed reads are scoped to, if one is chosen.
    public var currentConnection: Connection? {
        guard let currentConnectionID else { return nil }
        return connection(id: currentConnectionID)
    }

    public func connection(id: Int64) -> Connection? {
        connections.first { $0.id == id }
    }

    public func connection(kind: ServiceKind) -> Connection? {
        connections.first { $0.kind == kind }
    }

    /// The live media source and the health behind the feed.
    @Published public internal(set) var mediaStatus: MediaStatus = .unavailable
    /// Whether the database opened, and with it whether capture can run.
    @Published public internal(set) var captureAvailable = true
    @Published public internal(set) var failure: CaptureFailure?
    /// Set until a history read succeeds, even if a later write failure
    /// replaces the general `failure` shown in diagnostics.
    @Published public internal(set) var historyFailure: CaptureFailure?
    @Published public internal(set) var listens: [Listen] = []
    /// Total stored listens, including rows outside the loaded page.
    @Published public internal(set) var historyCount = 0
    /// Whether the store has another page after the loaded rows.
    @Published public internal(set) var historyHasMore = false
    /// Total listens per local day, keyed by the day's start. A day that spans
    /// a page boundary still reports its whole count.
    @Published public internal(set) var historyDayCounts: [Date: Int] = [:]
    @Published public internal(set) var listenCount = 0
    @Published public internal(set) var lastListen: Listen?
    /// The current track's cover, ready for the widget and now-playing strip.
    @Published public internal(set) var nowPlayingArtwork: Data?
    /// The raw track identity the cover and neutral sleeve are keyed on, so
    /// History, the widget and the strip draw the same sleeve for one track.
    @Published public internal(set) var nowPlayingArtworkIdentity: String?
    /// Covers already loaded from the store, by content hash.
    @Published public internal(set) var artworkByHash: [String: Data] = [:]

    public init() {}

    /// Queues a new-rule draft for the Edits page. Each request has a fresh
    /// identity so tapping Edit twice with the same track still starts a new
    /// draft.
    public func requestEditPrefill(_ match: SimpleEditRule.Match) {
        editPrefill = EditPrefill(match: match)
    }

    /// The Edits page takes the request once, so a later visit starts from the
    /// list rather than re-opening the same draft.
    public func takeEditPrefill() -> EditPrefill? {
        defer { editPrefill = nil }
        return editPrefill
    }
}

/// A new edit rule requested from the widget or the now-playing strip.
public struct EditPrefill: Equatable, Sendable {
    public let id: UUID
    public let match: SimpleEditRule.Match

    public init(match: SimpleEditRule.Match) {
        id = UUID()
        self.match = match
    }
}
