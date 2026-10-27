import Foundation

/// A saved block: four full-field patterns where a blank field matches
/// anything. A block with every field blank is refused.
///
/// Matching runs after sentinel cleanup and before any simple edit, so an edit
/// cannot rewrite a blocked track into an allowed one.
public struct BlockRule: Identifiable, Equatable, Sendable {
    /// Assigned by the store. `nil` until the block has been persisted.
    public let id: Int64?
    public var track: String
    public var artist: String
    public var album: String
    public var albumArtist: String
    /// When this version of the block was saved, the recency tie-break.
    public let savedAt: Date

    public init(
        id: Int64? = nil,
        track: String = "",
        artist: String = "",
        album: String = "",
        albumArtist: String = "",
        savedAt: Date = Date(),
    ) {
        self.id = id
        self.track = track
        self.artist = artist
        self.album = album
        self.albumArtist = albumArtist
        self.savedAt = savedAt
    }

    /// How many fields are filled. A blank field is a wildcard.
    public var activeCount: Int {
        MetadataField.allCases.count { !MetadataField.normalized(value(for: $0)).isEmpty }
    }

    public var validationError: BlockRuleValidationError? {
        activeCount > 0 ? nil : .noFields
    }

    public func stored(withID id: Int64, savedAt: Date) -> BlockRule {
        BlockRule(
            id: id,
            track: track,
            artist: artist,
            album: album,
            albumArtist: albumArtist,
            savedAt: savedAt,
        )
    }

    func matches(_ metadata: ListenMetadata) -> Bool {
        MetadataField.allCases.allSatisfy { field in
            let pattern = MetadataField.normalized(value(for: field))
            guard !pattern.isEmpty else { return true }
            return pattern == MetadataField.normalized(metadata.value(for: field))
        }
    }

    /// Evaluation order: more filled fields first, then newest first. The
    /// order only decides which rule is reported as the match; every match
    /// cancels the listen.
    public static func sortedForEvaluation(_ blocks: [BlockRule]) -> [BlockRule] {
        blocks.enumerated()
            .sorted { lhs, rhs in
                let left = lhs.element
                let right = rhs.element
                if left.activeCount != right.activeCount {
                    return left.activeCount > right.activeCount
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

    /// The most specific block matching `metadata`, if any. Callers cancel on
    /// a result and never treat a weaker match as an allow.
    public static func firstMatch(in blocks: [BlockRule], for metadata: ListenMetadata) -> BlockRule? {
        sortedForEvaluation(blocks).first {
            $0.validationError == nil && $0.matches(metadata)
        }
    }

    /// The case-insensitive identity of all four fields. A blank field is
    /// still part of the tuple even though it matches anything.
    var matchKey: String {
        MetadataField.tupleKey(MetadataField.allCases.map { value(for: $0) as String? })
    }
}

public enum BlockRuleValidationError: Error, Equatable, Sendable {
    case noFields
}

extension BlockRule {
    func value(for field: MetadataField) -> String {
        switch field {
        case .track: track
        case .artist: artist
        case .album: album
        case .albumArtist: albumArtist
        }
    }
}
