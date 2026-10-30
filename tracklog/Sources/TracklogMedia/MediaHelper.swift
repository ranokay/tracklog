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

/// One sample plus the artwork bytes the helper embedded in the same answer.
public struct MediaHelperSnapshot: Equatable, Sendable {
    public let sample: MediaSample
    public let artwork: Data?

    public init(sample: MediaSample, artwork: Data?) {
        self.sample = sample
        self.artwork = artwork
    }
}

/// One artwork read: a snapshot when the helper answered, unavailable when it
/// could not run. Artwork failing is never an error the caller shows.
public enum MediaHelperArtworkRead: Equatable, Sendable {
    case unavailable
    case snapshot(MediaHelperSnapshot)
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
    /// One `get --now` that keeps the embedded artwork. Called only when the
    /// track identity changes, never on the poll cadence.
    func readArtwork() async -> MediaHelperArtworkRead
}

public extension MediaHelperReading {
    /// A test double that does not model artwork reads has none.
    func readArtwork() async -> MediaHelperArtworkRead {
        .unavailable
    }
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

    public func readArtwork() async -> MediaHelperArtworkRead {
        let url = executableURL
        guard isExecutable else { return .unavailable }
        return await withCheckedContinuation { continuation in
            Self.queue.async {
                continuation.resume(returning: Self.readArtworkSync(helperURL: url))
            }
        }
    }

    private nonisolated static func readSync(helperURL: URL) -> MediaHelperRead {
        switch run(helperURL: helperURL, arguments: ["get", "--now", "--no-artwork"]) {
        case .missingExecutable:
            .missingExecutable
        case let .spawnFailed(message):
            .spawnFailed(message)
        case let .exitedNonZero(code):
            .exitedNonZero(code)
        case let .data(data):
            MediaHelperPayload.decode(data).map(MediaHelperRead.sample) ?? .empty
        }
    }

    private nonisolated static func readArtworkSync(helperURL: URL) -> MediaHelperArtworkRead {
        guard case let .data(data) = run(helperURL: helperURL, arguments: ["get", "--now"]),
              let snapshot = MediaHelperPayload.decodeSnapshot(data)
        else {
            return .unavailable
        }
        return .snapshot(snapshot)
    }

    private enum RunResult {
        case missingExecutable
        case spawnFailed(String)
        case exitedNonZero(Int32)
        case data(Data)
    }

    private nonisolated static func run(helperURL: URL, arguments: [String]) -> RunResult {
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            return .missingExecutable
        }

        let process = Process()
        process.executableURL = helperURL
        process.arguments = arguments

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
        return .data(data)
    }
}

/// The helper's `get --now` JSON, with or without `--no-artwork`, decoded.
///
/// Public so the sibling test package can exercise the payload shapes without
/// launching the helper. Everything is optional by design: Droppy's helper is
/// undocumented, and a changed payload reads as "nothing playing".
public enum MediaHelperPayload {
    public static func decode(_ data: Data) -> MediaSample? {
        decodeSnapshot(data)?.sample
    }

    /// The payload includes the cover bytes (`artworkData`). The separate
    /// `artworkIdentifier` URL is intentionally ignored: Tracklog never makes
    /// a network request for artwork.
    public static func decodeSnapshot(_ data: Data) -> MediaHelperSnapshot? {
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
        let payloadElapsed = payload["elapsedTime"] as? Double ?? 0
        let playbackRate = payload["playbackRate"] as? Double ?? 0
        let playing = payload["playing"] as? Bool ?? (playbackRate > 0)
        let bundleID = payload["parentApplicationBundleIdentifier"] as? String
            ?? payload["bundleIdentifier"] as? String
            ?? ""
        let observedAt = Date()
        let timestamp = timestamp(from: payload["timestamp"] as? String) ?? observedAt
        // The helper's get --now reports the track start and can keep
        // elapsedTime at zero. Derive the position from the observation clock
        // so polling advances played time; the reported timestamp still
        // reconstructs the start.
        let elapsedFromStart = playing ? max(0, observedAt.timeIntervalSince(timestamp)) : 0
        let elapsed = max(payloadElapsed, elapsedFromStart)
        let artwork = (payload["artworkData"] as? String)
            .flatMap { Data(base64Encoded: $0) }
            .flatMap { $0.isEmpty ? nil : $0 }

        return MediaHelperSnapshot(
            sample: MediaSample(
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
                observedAt: observedAt,
            ),
            artwork: artwork,
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
