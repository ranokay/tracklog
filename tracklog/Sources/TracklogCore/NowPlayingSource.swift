import Foundation

/// One stream of now-playing observations. Production is Droppy's media
/// helper, with Automation for Music or Spotify as its fallback; tests replay
/// an array of samples.
@MainActor
public protocol NowPlayingSource: AnyObject {
    /// The runtime health behind the feed, for Settings and diagnostics.
    var mediaStatus: MediaStatus { get }
    /// Starts the source and reports every health change.
    func start(
        onSample: @escaping @MainActor (MediaSample?) -> Void,
        onStatus: @escaping @MainActor (MediaStatus) -> Void,
    )
    func stop()
}

public extension NowPlayingSource {
    /// A source that does not report health is assumed to be working; its
    /// status is still the one stream the runtime reads.
    var mediaStatus: MediaStatus {
        .legacyAvailable
    }
}
