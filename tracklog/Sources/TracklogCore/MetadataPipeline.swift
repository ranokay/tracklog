import Foundation

/// Turns the player's metadata into the values history stores.
///
/// Its current stage is the final trim and the validity gate: a listen needs a
/// title and an artist after trimming. Cleanup, edits and blocks run before
/// this trim as they land.
public enum MetadataPipeline {
    public static func process(_ track: Track) -> ListenMetadata? {
        let processed = ListenMetadata(
            title: track.title.trimmingCharacters(in: .whitespacesAndNewlines),
            artist: track.artist.trimmingCharacters(in: .whitespacesAndNewlines),
            album: track.album.trimmingCharacters(in: .whitespacesAndNewlines),
            albumArtist: track.albumArtist.trimmingCharacters(in: .whitespacesAndNewlines),
        )
        guard !processed.title.isEmpty, !processed.artist.isEmpty else { return nil }
        return processed
    }
}
