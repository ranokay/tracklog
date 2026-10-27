import Foundation
import TracklogCore

/// One read of Droppy's bundled media helper.
///
/// A helper that cannot run reports why instead of throwing: the missing
/// executable, a spawn failure, a non-zero exit and a valid empty payload are
/// separate health states, and none of them is a crash.
public enum MediaHelperRead: Equatable, Sendable {
    case missingExecutable
    case spawnFailed(String)
    case exitedNonZero(Int32)
    case empty
    case sample(MediaSample)

    /// The health this read leaves the helper in.
    public var health: MediaStatus.HelperHealth {
        switch self {
        case .missingExecutable: .missingExecutable
        case let .spawnFailed(message): .spawnFailed(message)
        case let .exitedNonZero(code): .exitedNonZero(code)
        case .empty: .silent
        case .sample: .working
        }
    }

    /// The diagnostic line for a failed read, or nil when the read worked.
    public var failure: String? {
        switch self {
        case .missingExecutable: "Media helper is missing."
        case let .spawnFailed(message): "Media helper could not start: \(message)"
        case let .exitedNonZero(code): "Media helper exited with status \(code)"
        case .empty, .sample: nil
        }
    }
}

/// One poll of the helper. Production spawns Droppy's bundled executable;
/// tests replay the outcomes.
@MainActor
public protocol MediaHelperReading: AnyObject {
    /// The path the helper is expected at, whether or not it exists.
    var executablePath: String { get }
    /// Whether the executable exists now.
    var isExecutable: Bool { get }
    func read() async -> MediaHelperRead
}

/// Reads Droppy's bundled media helper.
///
/// The helper is Droppy's own now-playing reader: a separate executable with
/// a private MediaRemote shim inside it. It is undocumented, so everything
/// here fails soft. The helper is polled, never streamed: `stream` belongs to
/// Droppy's own player, and a flat one-second loop is not defensible.
@MainActor
public final class MediaHelperReader: MediaHelperReading {
    private let executableURL: URL

    private static let queue = DispatchQueue(label: "app.tracklog.media-helper", qos: .utility)

    public init(bundleURL: URL = Bundle.main.bundleURL) {
        executableURL = bundleURL
            .appendingPathComponent("Contents/Helpers/DroppyMediaHelper.app")
            .appendingPathComponent("Contents/MacOS/DroppyMediaHelper")
    }

    public var executablePath: String {
        executableURL.path
    }

    public var isExecutable: Bool {
        FileManager.default.isExecutableFile(atPath: executableURL.path)
    }

    public func read() async -> MediaHelperRead {
        let url = executableURL
        guard isExecutable else { return .missingExecutable }
        return await withCheckedContinuation { continuation in
            Self.queue.async {
                continuation.resume(returning: Self.readSync(helperURL: url))
            }
        }
    }

    private nonisolated static func readSync(helperURL: URL) -> MediaHelperRead {
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            return .missingExecutable
        }

        let process = Process()
        process.executableURL = helperURL
        process.arguments = ["get", "--now", "--no-artwork"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return .spawnFailed(error.localizedDescription)
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return .exitedNonZero(process.terminationStatus)
        }
        guard let sample = MediaHelperPayload.decode(data) else {
            return .empty
        }
        return .sample(sample)
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
