import Foundation

/// The four display fields of one listen, before or after the metadata
/// pipeline. Kept separate from ``Track`` so a stored listen can carry the raw
/// values the player reported beside the processed values history shows.
public struct ListenMetadata: Equatable, Sendable {
    public var title: String
    public var artist: String
    public var album: String
    public var albumArtist: String

    public init(title: String, artist: String = "", album: String = "", albumArtist: String = "") {
        self.title = title
        self.artist = artist
        self.album = album
        self.albumArtist = albumArtist
    }

    public init(_ track: Track) {
        self.init(title: track.title, artist: track.artist, album: track.album, albumArtist: track.albumArtist)
    }

    /// Case and surrounding whitespace are noise between polls.
    public var identity: String {
        Identity.joined([title, artist, album, albumArtist])
    }
}

/// One stored play. `raw` is what the player reported; `processed` is what the
/// metadata pipeline decided history should show.
public struct Listen: Identifiable, Equatable, Sendable {
    /// Assigned by the store. `nil` until the listen has been persisted.
    public let id: Int64?
    public let raw: ListenMetadata
    public let processed: ListenMetadata
    /// Bundle identifier of the app that owned the player.
    public let bundleID: String
    public let duration: TimeInterval
    public let playedDuration: TimeInterval
    /// The reconstructed start, not the moment the threshold fired.
    public let startedAt: Date
    /// When Tracklog persisted the listen.
    public let capturedAt: Date

    public init(
        id: Int64? = nil,
        raw: ListenMetadata,
        processed: ListenMetadata,
        bundleID: String,
        duration: TimeInterval,
        playedDuration: TimeInterval,
        startedAt: Date,
        capturedAt: Date,
    ) {
        self.id = id
        self.raw = raw
        self.processed = processed
        self.bundleID = bundleID
        self.duration = duration
        self.playedDuration = playedDuration
        self.startedAt = startedAt
        self.capturedAt = capturedAt
    }

    /// A captured scrobble, with the metadata history will show.
    public init(scrobble: Scrobble, processed: ListenMetadata, capturedAt: Date) {
        self.init(
            raw: ListenMetadata(scrobble.track),
            processed: processed,
            bundleID: scrobble.track.bundleID,
            duration: scrobble.track.duration,
            playedDuration: scrobble.playedDuration,
            startedAt: scrobble.playedAt,
            capturedAt: capturedAt,
        )
    }

    /// The durable duplicate key: raw identity plus the play's start.
    ///
    /// The start is quantized to whole seconds because that is the resolution
    /// every service accepts; a reload that reconstructs the start a fraction
    /// of a second differently still recognises the same play.
    public var dedupKey: String {
        let start = Int(startedAt.timeIntervalSince1970.rounded())
        return "\(raw.identity)\u{1E}\(Identity.normalized(bundleID))\u{1E}\(start)"
    }

    public func stored(withID id: Int64) -> Listen {
        Listen(
            id: id,
            raw: raw,
            processed: processed,
            bundleID: bundleID,
            duration: duration,
            playedDuration: playedDuration,
            startedAt: startedAt,
            capturedAt: capturedAt,
        )
    }
}

/// A failure the user must be able to copy into a bug report.
public struct CaptureFailure: Equatable, Sendable {
    public enum Stage: String, Sendable {
        case database
        case storage
        case history
    }

    public let stage: Stage
    public let message: String
    public let diagnostics: String

    public init(stage: Stage, message: String, diagnostics: String) {
        self.stage = stage
        self.message = message
        self.diagnostics = diagnostics
    }

    public static func database(url: URL, error: Error) -> CaptureFailure {
        CaptureFailure(
            stage: .database,
            message: "Local history is unavailable, so capturing is off.",
            diagnostics: """
            Tracklog could not open its local history database.
            File: \(url.path)
            Error: \(error)
            """,
        )
    }

    public static func storage(error: Error) -> CaptureFailure {
        CaptureFailure(
            stage: .storage,
            message: "This listen could not be saved, so it was not kept.",
            diagnostics: "Tracklog could not write to its local history database.\nError: \(error)",
        )
    }

    /// A read failed. A listen inserted just before a failed refresh is still
    /// stored, so this never claims that anything was lost.
    public static func history(error: Error) -> CaptureFailure {
        CaptureFailure(
            stage: .history,
            message: "History could not be loaded from this Mac.",
            diagnostics: "Tracklog could not read its local history database.\nError: \(error)",
        )
    }
}
