import Foundation

/// The portable settings document. Every field here is a durable preference
/// the listener may move to another Mac; credentials, connections, history,
/// deliveries, artwork, feedback, the current connection and the pause-until
/// timestamp deliberately have no representation.
///
/// The version is the document's own schema version, independent of the
/// database schema and the app version. A later section can join without a
/// migration because decoding ignores unknown keys.
public struct SettingsExport: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let settings: SettingsExportSettings
    public let apps: [SettingsExportApp]
    public let simpleEdits: [SettingsExportSimpleEdit]
    public let blocks: [SettingsExportBlock]

    public init(
        settings: SettingsExportSettings,
        apps: [SettingsExportApp],
        simpleEdits: [SettingsExportSimpleEdit],
        blocks: [SettingsExportBlock],
        version: Int = SettingsExport.currentVersion,
    ) {
        self.version = version
        self.settings = settings
        self.apps = apps
        self.simpleEdits = simpleEdits
        self.blocks = blocks
    }

    /// Builds the document from the runtime's durable settings and the rows a
    /// store just returned. Order is preserved so the file matches the rules
    /// the pipeline will apply.
    public init(
        settings: CaptureSettings,
        apps: [SeenApp],
        edits: [SimpleEditRule],
        blocks: [BlockRule],
    ) {
        self.init(
            settings: SettingsExportSettings(settings),
            apps: apps.map(SettingsExportApp.init),
            simpleEdits: edits.map(SettingsExportSimpleEdit.init),
            blocks: blocks.map(SettingsExportBlock.init),
        )
    }

    /// Pretty and sorted so two exports of the same settings are byte-equal.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> SettingsExport {
        try JSONDecoder().decode(SettingsExport.self, from: data)
    }

    enum CodingKeys: String, CodingKey {
        case version
        case settings
        case apps
        case simpleEdits = "simple_edits"
        case blocks
    }
}

/// The three durable capture switches. The pause is excluded: it references
/// this session, not a portable preference.
public struct SettingsExportSettings: Codable, Equatable, Sendable {
    public let scrobblingEnabled: Bool
    public let nowPlayingEnabled: Bool
    public let minimumDuration: TimeInterval

    public init(
        scrobblingEnabled: Bool,
        nowPlayingEnabled: Bool,
        minimumDuration: TimeInterval,
    ) {
        self.scrobblingEnabled = scrobblingEnabled
        self.nowPlayingEnabled = nowPlayingEnabled
        self.minimumDuration = minimumDuration
    }

    init(_ settings: CaptureSettings) {
        self.init(
            scrobblingEnabled: settings.scrobblingEnabled,
            nowPlayingEnabled: settings.nowPlayingEnabled,
            minimumDuration: settings.minimumDuration,
        )
    }

    enum CodingKeys: String, CodingKey {
        case scrobblingEnabled = "scrobbling_enabled"
        case nowPlayingEnabled = "now_playing_enabled"
        case minimumDuration = "minimum_duration"
    }
}

public struct SettingsExportApp: Codable, Equatable, Sendable {
    public let bundleID: String
    public let isAllowed: Bool

    public init(bundleID: String, isAllowed: Bool) {
        self.bundleID = bundleID
        self.isAllowed = isAllowed
    }

    init(_ app: SeenApp) {
        self.init(bundleID: app.bundleID, isAllowed: app.isAllowed)
    }

    enum CodingKeys: String, CodingKey {
        case bundleID = "bundle_id"
        case isAllowed = "allowed"
    }
}

public struct SettingsExportSimpleEdit: Codable, Equatable, Sendable {
    public let match: SettingsExportMatch
    public let replacement: SettingsExportReplacement

    public init(match: SettingsExportMatch, replacement: SettingsExportReplacement) {
        self.match = match
        self.replacement = replacement
    }

    init(_ rule: SimpleEditRule) {
        self.init(
            match: SettingsExportMatch(rule.match),
            replacement: SettingsExportReplacement(rule.replacement),
        )
    }
}

public struct SettingsExportMatch: Codable, Equatable, Sendable {
    public let track: String?
    public let artist: String?
    public let album: String?
    public let albumArtist: String?

    public init(
        track: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        albumArtist: String? = nil,
    ) {
        self.track = track
        self.artist = artist
        self.album = album
        self.albumArtist = albumArtist
    }

    init(_ match: SimpleEditRule.Match) {
        self.init(
            track: match.track,
            artist: match.artist,
            album: match.album,
            albumArtist: match.albumArtist,
        )
    }

    enum CodingKeys: String, CodingKey {
        case track
        case artist
        case album
        case albumArtist = "album_artist"
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(track, forKey: .track)
        try container.encode(artist, forKey: .artist)
        try container.encode(album, forKey: .album)
        try container.encode(albumArtist, forKey: .albumArtist)
    }
}

public struct SettingsExportReplacement: Codable, Equatable, Sendable {
    public let track: String?
    public let artist: String?
    public let album: String?
    public let albumArtist: String?

    public init(
        track: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        albumArtist: String? = nil,
    ) {
        self.track = track
        self.artist = artist
        self.album = album
        self.albumArtist = albumArtist
    }

    init(_ replacement: SimpleEditRule.Replacement) {
        self.init(
            track: replacement.track,
            artist: replacement.artist,
            album: replacement.album,
            albumArtist: replacement.albumArtist,
        )
    }

    enum CodingKeys: String, CodingKey {
        case track
        case artist
        case album
        case albumArtist = "album_artist"
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(track, forKey: .track)
        try container.encode(artist, forKey: .artist)
        try container.encode(album, forKey: .album)
        try container.encode(albumArtist, forKey: .albumArtist)
    }
}

public struct SettingsExportBlock: Codable, Equatable, Sendable {
    public let track: String
    public let artist: String
    public let album: String
    public let albumArtist: String

    public init(track: String, artist: String, album: String, albumArtist: String) {
        self.track = track
        self.artist = artist
        self.album = album
        self.albumArtist = albumArtist
    }

    init(_ block: BlockRule) {
        self.init(
            track: block.track,
            artist: block.artist,
            album: block.album,
            albumArtist: block.albumArtist,
        )
    }

    enum CodingKeys: String, CodingKey {
        case track
        case artist
        case album
        case albumArtist = "album_artist"
    }
}

/// Why an export could not be built. A read failure is surfaced instead of
/// writing an incomplete document.
public struct SettingsExportReadFailure: Error, Equatable, CustomStringConvertible, Sendable {
    public let section: String
    public let message: String

    public init(section: String, message: String) {
        self.section = section
        self.message = message
    }

    public var description: String {
        "The \(section) could not be read: \(message)"
    }
}
