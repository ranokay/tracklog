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
    /// The connection whose browser sign-in is open on its page. The page
    /// model itself lives in the droplet.
    @Published public internal(set) var reauthConnectionID: Int64?
    /// Set until a connection read succeeds, so the Services page can say the
    /// list is unavailable rather than empty.
    @Published public internal(set) var connectionsFailure: CaptureFailure?
    /// Why Last.fm rejected the app credentials in use, compiled or override.
    /// This is distinct from a connection's own needs-sign-in state.
    @Published public internal(set) var lastFMAppCredentialProblem: AppCredentialProblem?
    /// Whether the compiled Last.fm pair has both halves.
    @Published public internal(set) var lastFMCompiledCredentialsPresent =
        LastFMAppCredentials.compiled.isConfigured
    /// Whether a Keychain override is saved. The pair itself is never published.
    @Published public internal(set) var lastFMOverridePresent = false
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

    /// Whether any Last.fm app pair can sign a call. A pair that Last.fm
    /// rejected is present but unusable, so the remedy check below also reads
    /// the problem.
    public var lastFMAppCredentialsAvailable: Bool {
        lastFMCompiledCredentialsPresent || lastFMOverridePresent
    }

    /// Whether Add Last.fm must send the listener to the app-credentials page
    /// instead of a sign-in that would fail. An empty pair and a rejected pair
    /// share the same remedy.
    public var lastFMNeedsAppCredentialRemedy: Bool {
        !lastFMAppCredentialsAvailable || lastFMAppCredentialProblem != nil
    }

    /// The connection service-backed reads are scoped to, if one is chosen.
    public var currentConnection: Connection? {
        guard let currentConnectionID else { return nil }
        return connection(id: currentConnectionID)
    }

    public func connection(id: Int64) -> Connection? {
        connections.first { $0.id == id }
    }

    /// The connection a page or row refers to. A configurable service can have
    /// several, so a caller that names a root gets that one; every other caller
    /// gets the first of its kind.
    public func connection(kind: ServiceKind, endpoint: ServiceEndpoint? = nil) -> Connection? {
        connections.first {
            $0.kind == kind && (endpoint == nil || $0.endpoint == endpoint)
        }
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
    /// Local love/hate knowledge, keyed by processed metadata identity.
    @Published public internal(set) var feedbackByTrack: [String: TrackFeedback] = [:]
    /// Which feedback actions the current connection set can perform.
    @Published public internal(set) var feedbackSupport = FeedbackSupport()
    /// Deliveries for the listens on the loaded page, keyed by listen id.
    @Published public internal(set) var deliveriesByListen: [Int64: [Delivery]] = [:]
    /// Every pending delivery, grouped by connection, regardless of which
    /// history page is loaded.
    @Published public internal(set) var pendingQueue = PendingQueue()
    /// Whether the pending list is open beneath the banner. The queue badge
    /// opens History with this already set.
    @Published public internal(set) var pendingListExpanded = false
    /// The nested Settings page the harness is previewing. Production never
    /// sets this; the host's own page opener drives nested pages there.
    @Published public internal(set) var harnessSettingsPage: String?

    public var pendingCount: Int {
        pendingQueue.count
    }

    /// The one banner the History feed shows, highest priority first.
    public var pendingBanner: HistoryBanner? {
        HistoryBanner.resolve(
            feedAvailable: feedAvailable,
            connections: connections,
            pending: pendingQueue,
        )
    }

    public func deliveries(for listen: Listen) -> [Delivery] {
        guard let id = listen.id else { return [] }
        return deliveriesByListen[id] ?? []
    }

    /// The local feedback for one processed identity.
    public func feedback(for identity: String) -> TrackFeedback? {
        feedbackByTrack[identity]
    }

    /// The heart state the Sleeve widget reads for the current track. The key
    /// is the processed metadata identity, so a change of source player does
    /// not change the heart.
    public var nowPlayingFeedback: TrackFeedback? {
        guard let track = nowPlaying?.track else { return nil }
        return feedbackByTrack[ListenMetadata(track).identity]
    }

    public var nowPlayingIsLoved: Bool {
        nowPlayingFeedback?.score == .loved
    }

    public func setPendingListExpanded(_ expanded: Bool) {
        pendingListExpanded = expanded
    }

    public func setReauthConnection(_ id: Int64?) {
        reauthConnectionID = id
    }

    public func setHarnessSettingsPage(_ id: String?) {
        harnessSettingsPage = id
    }

    public func togglePendingList() {
        pendingListExpanded.toggle()
    }

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
