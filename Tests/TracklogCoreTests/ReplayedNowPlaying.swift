import Foundation
import TracklogCore

@MainActor
final class ReplayedNowPlaying: NowPlayingSource {
    var mediaStatus: MediaStatus = .legacyAvailable
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var handler: ((MediaSample?) -> Void)?
    private(set) var statusHandler: ((MediaStatus) -> Void)?
    /// The bytes returned by the source's one-shot artwork lookup.
    var artworkData: Data?
    /// Set to make the lookup take observable time without blocking capture.
    var artworkDelay: Duration?
    private(set) var artworkLookups: [String] = []

    func artwork(for track: Track) async -> Data? {
        artworkLookups.append(ListenMetadata(track).identity)
        if let artworkDelay {
            try? await Task.sleep(for: artworkDelay)
        }
        return artworkData
    }

    func start(
        onSample: @escaping @MainActor (MediaSample?) -> Void,
        onStatus: @escaping @MainActor (MediaStatus) -> Void,
    ) {
        startCount += 1
        handler = onSample
        statusHandler = onStatus
        onStatus(mediaStatus)
    }

    func emitStatus(_ status: MediaStatus) {
        mediaStatus = status
        statusHandler?(status)
    }

    func stop() {
        stopCount += 1
        handler = nil
        statusHandler = nil
    }
}
