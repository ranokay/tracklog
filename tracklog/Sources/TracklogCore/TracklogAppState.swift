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
    @Published public internal(set) var listens: [Listen] = []
    @Published public internal(set) var listenCount = 0
    @Published public internal(set) var lastListen: Listen?

    public init() {}
}
