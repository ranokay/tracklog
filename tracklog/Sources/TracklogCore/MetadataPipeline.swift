import Foundation

/// Turns the player's metadata into the values history stores.
///
/// The stages run in the order the metadata pipeline specifies: sentinel
/// cleanup, simple edits, then the final trim and validity gate. A listen
/// needs a title and an artist after trimming.
public enum MetadataPipeline {
    /// Album and album artist values the player uses when it has nothing.
    /// Plain, square-bracketed and angle-bracketed forms, matched after
    /// trimming and case folding.
    static let unknownPlaceholders: Set<String> = [
        "unknown",
        "[unknown]",
        "<unknown>",
        "unknown album",
        "[unknown album]",
        "<unknown album>",
        "unknown artist",
        "[unknown artist]",
        "<unknown artist>",
    ]

    public static func process(_ track: Track, edits: [SimpleEditRule] = []) -> ListenMetadata? {
        let cleaned = sentinelCleanup(ListenMetadata(track))
        let edited = SimpleEditRule.apply(edits, to: cleaned)
        let processed = ListenMetadata(
            title: edited.title.trimmingCharacters(in: .whitespacesAndNewlines),
            artist: edited.artist.trimmingCharacters(in: .whitespacesAndNewlines),
            album: edited.album.trimmingCharacters(in: .whitespacesAndNewlines),
            albumArtist: edited.albumArtist.trimmingCharacters(in: .whitespacesAndNewlines),
        )
        guard !processed.title.isEmpty, !processed.artist.isEmpty else { return nil }
        return processed
    }

    /// Pre-rule cleanup. Artist has one placeholder (`va`); album and album
    /// artist have the unknown set; album artist also maps `VA` to the
    /// conventional Various Artists label. Title is never cleaned.
    static func sentinelCleanup(_ metadata: ListenMetadata) -> ListenMetadata {
        var cleaned = metadata
        if MetadataField.normalized(cleaned.artist) == "va" {
            cleaned.artist = ""
        }
        if isUnknownPlaceholder(cleaned.album) {
            cleaned.album = ""
        }
        if isUnknownPlaceholder(cleaned.albumArtist) {
            cleaned.albumArtist = ""
        }
        if MetadataField.normalized(cleaned.albumArtist) == "va" {
            cleaned.albumArtist = "Various Artists"
        }
        return cleaned
    }

    private static func isUnknownPlaceholder(_ value: String) -> Bool {
        unknownPlaceholders.contains(MetadataField.normalized(value))
    }
}
