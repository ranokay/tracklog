import Foundation

/// The four metadata fields a rule can match or replace.
enum MetadataField: CaseIterable, Hashable, Sendable {
    case track
    case artist
    case album
    case albumArtist

    static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The case-insensitive identity of a rule's tuple.
    ///
    /// A `nil` value is an inactive field, which is a simple edit's wildcard.
    /// A non-nil value is active even when empty. Values are length-prefixed
    /// so a value containing the separator cannot collide with another tuple.
    static func tupleKey(_ values: [String?]) -> String {
        allCases.indices
            .map { index in
                guard let value = values[index] else { return "0" }
                let normalized = normalized(value)
                return "1:\(normalized.count):\(normalized)"
            }
            .joined(separator: "\u{1E}")
    }
}

extension ListenMetadata {
    func value(for field: MetadataField) -> String {
        switch field {
        case .track: title
        case .artist: artist
        case .album: album
        case .albumArtist: albumArtist
        }
    }

    mutating func set(_ value: String, for field: MetadataField) {
        switch field {
        case .track: title = value
        case .artist: artist = value
        case .album: album = value
        case .albumArtist: albumArtist = value
        }
    }
}
