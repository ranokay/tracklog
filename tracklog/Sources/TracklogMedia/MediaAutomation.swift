import AppKit
import Foundation
import TracklogCore

/// One scriptable player the Automation fallback may probe.
public struct MediaAutomationCandidate: Equatable, Sendable {
    public let bundleID: String
    public let displayName: String
    /// The source Settings names while this candidate speaks.
    public let sourceKind: MediaSourceKind
    /// Spotify reports duration in milliseconds; Music reports seconds.
    public let durationIsMilliseconds: Bool

    public init(
        bundleID: String,
        displayName: String,
        sourceKind: MediaSourceKind,
        durationIsMilliseconds: Bool,
    ) {
        self.bundleID = bundleID
        self.displayName = displayName
        self.sourceKind = sourceKind
        self.durationIsMilliseconds = durationIsMilliseconds
    }

    public static let music = MediaAutomationCandidate(
        bundleID: "com.apple.Music",
        displayName: "Music",
        sourceKind: .musicAutomation,
        durationIsMilliseconds: false,
    )

    public static let spotify = MediaAutomationCandidate(
        bundleID: "com.spotify.client",
        displayName: "Spotify",
        sourceKind: .spotifyAutomation,
        durationIsMilliseconds: true,
    )

    /// Music first, then Spotify, so two playing players resolve the same way
    /// on every probe.
    public static let defaults = [music, spotify]
}

/// What one Automation probe saw.
public enum MediaAutomationProbe: Equatable, Sendable {
    case notRunning
    case paused
    case stopped
    case playing(MediaSample)
    case denied
    case failed(String)
}

/// Runs one probe against one candidate. Production executes AppleScript in
/// Droppy's process, so TCC attributes the request to Droppy; tests replay a
/// result.
@MainActor
public protocol MediaAutomationProbing: AnyObject {
    func probe(_ candidate: MediaAutomationCandidate) async -> MediaAutomationProbe
}

/// Executes a candidate's fixed script on a serial queue, off the main actor.
///
/// `NSAppleScript` is not thread-safe, but a script is compiled and executed
/// on the same queue, and the result crosses back as a sendable value.
@MainActor
public final class AppleScriptAutomationProbe: MediaAutomationProbing {
    private static let queue = DispatchQueue(label: "app.tracklog.media-automation", qos: .utility)

    public init() {}

    public func probe(_ candidate: MediaAutomationCandidate) async -> MediaAutomationProbe {
        await withCheckedContinuation { continuation in
            Self.queue.async {
                continuation.resume(returning: Self.probeSync(candidate))
            }
        }
    }

    private nonisolated static func probeSync(_ candidate: MediaAutomationCandidate) -> MediaAutomationProbe {
        switch candidate.sourceKind {
        case .musicAutomation:
            probeMusic(candidate)
        case .spotifyAutomation:
            probeSpotify(candidate)
        default:
            .failed("Unsupported Automation player \(candidate.displayName)")
        }
    }

    private nonisolated static func probeMusic(_ candidate: MediaAutomationCandidate) -> MediaAutomationProbe {
        guard let script = NSAppleScript(source: """
        tell application "Music"
            set stateText to (player state as string)
            if stateText is not "playing" then return stateText
            set currentTrack to current track
            set sep to (ASCII character 31)
            set titleText to ""
            try
                set titleText to (name of currentTrack) as string
            end try
            set artistText to ""
            try
                set artistText to (artist of currentTrack) as string
            end try
            set albumText to ""
            try
                set albumText to (album of currentTrack) as string
            end try
            set albumArtistText to ""
            try
                set albumArtistText to (album artist of currentTrack) as string
            end try
            set durationText to "0"
            try
                set durationText to ((duration of currentTrack) as integer) as string
            end try
            set positionText to "0"
            try
                set positionText to ((player position) as integer) as string
            end try
            set outputText to stateText & sep & titleText & sep & artistText
            set outputText to outputText & sep & albumText & sep & albumArtistText
            set outputText to outputText & sep & durationText & sep & positionText
            return outputText
        end tell
        """) else {
            return .failed("Could not compile the \(candidate.displayName) script")
        }
        return execute(script, for: candidate)
    }

    private nonisolated static func probeSpotify(_ candidate: MediaAutomationCandidate) -> MediaAutomationProbe {
        guard let script = NSAppleScript(source: """
        tell application "Spotify"
            set stateText to (player state as string)
            if stateText is not "playing" then return stateText
            set currentTrack to current track
            set sep to (ASCII character 31)
            set titleText to ""
            try
                set titleText to (name of currentTrack) as string
            end try
            set artistText to ""
            try
                set artistText to (artist of currentTrack) as string
            end try
            set albumText to ""
            try
                set albumText to (album of currentTrack) as string
            end try
            set albumArtistText to ""
            try
                set albumArtistText to (album artist of currentTrack) as string
            end try
            set durationText to "0"
            try
                set durationText to ((duration of currentTrack) as integer) as string
            end try
            set positionText to "0"
            try
                set positionText to ((player position) as integer) as string
            end try
            set outputText to stateText & sep & titleText & sep & artistText
            set outputText to outputText & sep & albumText & sep & albumArtistText
            set outputText to outputText & sep & durationText & sep & positionText
            return outputText
        end tell
        """) else {
            return .failed("Could not compile the \(candidate.displayName) script")
        }
        return execute(script, for: candidate)
    }

    private nonisolated static func execute(
        _ script: NSAppleScript,
        for candidate: MediaAutomationCandidate,
    ) -> MediaAutomationProbe {
        var error: NSDictionary?
        let output = script.executeAndReturnError(&error)

        if let error {
            let number = error[NSAppleScript.errorNumber] as? Int ?? 0
            let message = error[NSAppleScript.errorMessage] as? String ?? "AppleScript failed"
            switch number {
            case -1743: return .denied
            case -600, -609: return .notRunning
            default: return .failed(message)
            }
        }

        return MediaAutomationOutput.parse(output.stringValue ?? "", for: candidate)
    }
}

/// The field separator the scripts emit and the parser splits on. Track names
/// can contain any printable character, so this is an ASCII unit separator.
public enum MediaAutomationOutput {
    public static let fieldSeparator = "\u{1F}"

    public static func parse(_ output: String, for candidate: MediaAutomationCandidate) -> MediaAutomationProbe {
        let fields = output
            .components(separatedBy: fieldSeparator)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        guard let state = fields.first, !state.isEmpty else {
            return .failed("Automation returned no player state")
        }

        switch state.lowercased() {
        case "playing":
            guard fields.count >= 7, !fields[1].isEmpty else {
                return .failed("Automation returned a playing state without a track")
            }
            let duration = Double(fields[5]) ?? 0
            let elapsed = Double(fields[6]) ?? 0
            return .playing(MediaSample(
                track: Track(
                    title: fields[1],
                    artist: fields[2],
                    album: fields[3],
                    albumArtist: fields[4],
                    duration: candidate.durationIsMilliseconds ? duration / 1000 : duration,
                    bundleID: candidate.bundleID,
                ),
                elapsed: elapsed,
                playbackRate: 1,
                isPlaying: true,
            ))
        case "stopped":
            return .stopped
        default:
            return .paused
        }
    }
}

/// Whether a candidate app is running. Checked before a probe so AppleScript
/// never launches an app that is not already open.
public enum MediaPlayerProcess {
    @MainActor
    public static func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }
}
