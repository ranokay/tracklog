import Foundation

/// The artwork half of local history: one blob per content hash, and the
/// mapping from a track's identity to the cover its listens reference.
public protocol ArtworkStore: Sendable {
    /// The stored bytes for one content hash, or nil when that cover was never
    /// saved.
    func artwork(for hash: String) async throws -> Data?
    /// The cover a new listen of this track should reference.
    func artworkHash(forTrack identity: String) async throws -> String?
    /// Saves normalized artwork for a track. Cover-less stored listens of that
    /// track are filled in; listens that already reference a cover keep it.
    func attachArtwork(_ artwork: StoredArtwork, toTrack identity: String) async throws
}
