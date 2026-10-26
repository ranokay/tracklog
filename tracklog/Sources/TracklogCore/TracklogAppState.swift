import Combine
import Foundation

/// The one observable app state the droplet's views read.
@MainActor
public final class TracklogAppState: ObservableObject {
    @Published public internal(set) var scrobblingEnabled = false
    @Published public internal(set) var nowPlaying: MediaSample?
    @Published public internal(set) var status: ScrobbleStatus = .idle
    @Published public internal(set) var feedAvailable = true
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

    public init() {}
}
