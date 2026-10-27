import Foundation

/// A saved simple edit: a set of active match fields and the replacements it
/// supplies when they all match.
///
/// `nil` means "not active": a wildcard in a match, or "leave the field alone"
/// in a replacement. An active empty replacement clears album and album
/// artist, and is ignored for track and artist.
public struct SimpleEditRule: Identifiable, Equatable, Sendable {
    public struct Match: Equatable, Sendable {
        public var track: String?
        public var artist: String?
        public var album: String?
        public var albumArtist: String?

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

        public var activeCount: Int {
            [track, artist, album, albumArtist].compactMap(\.self).count
        }

        func matches(_ metadata: ListenMetadata) -> Bool {
            Self.field(track, matches: metadata.title)
                && Self.field(artist, matches: metadata.artist)
                && Self.field(album, matches: metadata.album)
                && Self.field(albumArtist, matches: metadata.albumArtist)
        }

        private static func field(_ match: String?, matches value: String) -> Bool {
            guard let match else { return true }
            return MetadataField.normalized(match) == MetadataField.normalized(value)
        }
    }

    public struct Replacement: Equatable, Sendable {
        public var track: String?
        public var artist: String?
        public var album: String?
        public var albumArtist: String?

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

        public var activeCount: Int {
            [track, artist, album, albumArtist].compactMap(\.self).count
        }
    }

    /// Assigned by the store. `nil` until the rule has been persisted.
    public let id: Int64?
    public var match: Match
    public var replacement: Replacement
    /// When this version of the rule was saved, the recency tie-break.
    public let savedAt: Date

    public init(
        id: Int64? = nil,
        match: Match,
        replacement: Replacement,
        savedAt: Date = Date(),
    ) {
        self.id = id
        self.match = match
        self.replacement = replacement
        self.savedAt = savedAt
    }

    public var validationError: SimpleEditRuleValidationError? {
        guard match.activeCount > 0 else { return .noMatchFields }
        guard replacement.activeCount > 0 else { return .noReplacements }
        if let track = replacement.track, MetadataField.normalized(track).isEmpty {
            return .cannotClearTrack
        }
        if let artist = replacement.artist, MetadataField.normalized(artist).isEmpty {
            return .cannotClearArtist
        }
        return nil
    }

    public func stored(withID id: Int64, savedAt: Date) -> SimpleEditRule {
        SimpleEditRule(id: id, match: match, replacement: replacement, savedAt: savedAt)
    }

    // MARK: - Application

    /// Application order: more active match fields first, then newest first.
    /// Rules with the same specificity and timestamp keep their input order.
    public static func sortedForApplication(_ rules: [SimpleEditRule]) -> [SimpleEditRule] {
        rules.enumerated()
            .sorted { lhs, rhs in
                let left = lhs.element
                let right = rhs.element
                if left.match.activeCount != right.match.activeCount {
                    return left.match.activeCount > right.match.activeCount
                }
                if left.savedAt != right.savedAt {
                    return left.savedAt > right.savedAt
                }
                if left.id != right.id {
                    return (left.id ?? -1) > (right.id ?? -1)
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    /// Merges every matching rule field by field against the metadata they all
    /// matched. A rule's match is never re-evaluated against another rule's
    /// output: there is no chaining.
    public static func apply(_ rules: [SimpleEditRule], to metadata: ListenMetadata) -> ListenMetadata {
        var merged = metadata
        var claimed: Set<MetadataField> = []

        for rule in sortedForApplication(rules) where rule.match.matches(metadata) {
            for field in MetadataField.allCases where !claimed.contains(field) {
                guard let replacement = rule.replacement.value(for: field) else { continue }
                let trimmed = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
                switch field {
                case .track, .artist:
                    // An empty replacement cannot mean "clear" for either: the
                    // incoming value survives and a less specific rule may
                    // still fill the field.
                    guard !trimmed.isEmpty else { continue }
                case .album, .albumArtist:
                    // An active empty replacement clears the field.
                    break
                }
                merged.set(replacement, for: field)
                claimed.insert(field)
            }
        }
        return merged
    }

    /// The case-insensitive, trimmed identity of the active match fields.
    var matchKey: String {
        MetadataField.tupleKey(MetadataField.allCases.map { match.value(for: $0) })
    }
}

public enum SimpleEditRuleValidationError: Error, Equatable, Sendable {
    case noMatchFields
    case noReplacements
    case cannotClearTrack
    case cannotClearArtist
}

// MARK: - Field plumbing

public extension SimpleEditRule.Match {
    /// A new rule's match fields, pre-filled from a listen's metadata as the
    /// pipeline will match it. A field is active only when it has a value, so
    /// the Edits form enables album and album artist only when they exist.
    static func prefilled(from metadata: ListenMetadata) -> SimpleEditRule.Match {
        SimpleEditRule.Match(
            track: active(metadata.title),
            artist: active(metadata.artist),
            album: active(metadata.album),
            albumArtist: active(metadata.albumArtist),
        )
    }

    private static func active(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension SimpleEditRule.Match {
    func value(for field: MetadataField) -> String? {
        switch field {
        case .track: track
        case .artist: artist
        case .album: album
        case .albumArtist: albumArtist
        }
    }
}

extension SimpleEditRule.Replacement {
    func value(for field: MetadataField) -> String? {
        switch field {
        case .track: track
        case .artist: artist
        case .album: album
        case .albumArtist: albumArtist
        }
    }
}
