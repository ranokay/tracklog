import Foundation

/// One stream of now-playing observations. Production is Droppy's media
/// helper; tests replay an array of samples.
@MainActor
public protocol NowPlayingSource: AnyObject {
    /// Whether the source can currently produce samples at all.
    var isAvailable: Bool { get }
    func start(onSample: @escaping @MainActor (MediaSample?) -> Void)
    func stop()
}
