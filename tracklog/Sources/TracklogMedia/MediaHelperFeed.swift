import Foundation
import TracklogCore

/// Reads Droppy's bundled media helper.
///
/// The helper is Droppy's own now-playing reader: a separate executable with a
/// private MediaRemote shim inside it. It is undocumented, so everything here
/// fails soft — a missing helper, a changed payload or a helper that exits
/// non-zero all read as "nothing playing", never as a crash.
///
/// The helper is polled, not streamed: `stream` belongs to Droppy's own
/// player. Two seconds while enabled is the budget the research found
/// defensible; a flat one-second loop is not.
@MainActor
public final class MediaHelperFeed: NowPlayingSource {
    public typealias Handler = @MainActor (MediaSample?) -> Void

    public private(set) var isAvailable: Bool

    private let helperURL: URL?
    private let queue = DispatchQueue(label: "app.tracklog.media-helper", qos: .utility)
    private var pollTask: Task<Void, Never>?
    private var handler: Handler?

    public init(bundleURL: URL = Bundle.main.bundleURL) {
        let url = bundleURL
            .appendingPathComponent("Contents/Helpers/DroppyMediaHelper.app")
            .appendingPathComponent("Contents/MacOS/DroppyMediaHelper")
        helperURL = FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        isAvailable = helperURL != nil
    }

    public func start(onSample: @escaping Handler) {
        guard pollTask == nil else { return }
        handler = onSample

        guard let helperURL else {
            onSample(nil)
            return
        }

        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let sample = await read(helperURL: helperURL)
                guard !Task.isCancelled else { return }
                handler?(sample)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
        handler = nil
    }

    private func read(helperURL: URL) async -> MediaSample? {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: Self.readSync(helperURL: helperURL))
            }
        }
    }

    private nonisolated static func readSync(helperURL: URL) -> MediaSample? {
        let process = Process()
        process.executableURL = helperURL
        process.arguments = ["get", "--now", "--no-artwork"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return MediaHelperPayload.decode(data)
        } catch {
            return nil
        }
    }
}

/// The helper's `get --now --no-artwork` JSON, decoded.
///
/// Public so the sibling test package can exercise the payload shapes without
/// launching the helper. Everything is optional by design: Droppy's helper is
/// undocumented, and a changed payload reads as "nothing playing".
public enum MediaHelperPayload {
    public static func decode(_ data: Data) -> MediaSample? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let payload = object["payload"] as? [String: Any],
            let title = payload["title"] as? String,
            !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }

        let artist = payload["artist"] as? String ?? ""
        let album = payload["album"] as? String ?? ""
        let albumArtist = payload["albumArtist"] as? String ?? ""
        let duration = payload["duration"] as? Double ?? 0
        let elapsed = payload["elapsedTime"] as? Double ?? 0
        let playbackRate = payload["playbackRate"] as? Double ?? 0
        let playing = payload["playing"] as? Bool ?? (playbackRate > 0)
        let bundleID = payload["parentApplicationBundleIdentifier"] as? String
            ?? payload["bundleIdentifier"] as? String
            ?? ""
        let timestamp = timestamp(from: payload["timestamp"] as? String) ?? Date()

        return MediaSample(
            track: Track(
                title: title,
                artist: artist,
                album: album,
                albumArtist: albumArtist,
                duration: duration,
                bundleID: bundleID,
            ),
            elapsed: elapsed,
            playbackRate: playbackRate,
            isPlaying: playing,
            timestamp: timestamp,
        )
    }

    /// Droppy emits milliseconds and the Playground whole seconds; both are
    /// valid ISO 8601. A missing or malformed value falls back to now.
    private static func timestamp(from string: String?) -> Date? {
        guard let string else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) {
            return date
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }
}
