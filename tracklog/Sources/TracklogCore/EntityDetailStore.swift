import Foundation

/// The local detail reads. SQLite implements them on its dedicated read-only
/// connection so a full-history scan never occupies capture.
public protocol EntityLocalReading: Sendable {
    func entityLocalDetail(
        kind: EntityKind,
        key: String,
        topTrackLimit: Int,
    ) async throws -> EntityLocalDetail
}

/// The durable user-chosen images. A key is the local chart grouping key, so
/// the same override answers every connection.
public protocol ImageOverrideStore: Sendable {
    func imageOverrides() async throws -> [ImageOverride]
    func imageOverride(kind: EntityKind, key: String) async throws -> ImageOverride?
    func saveImageOverride(_ override: ImageOverride, artwork: StoredArtwork) async throws
    func removeImageOverride(kind: EntityKind, key: String) async throws
}

/// The durable iTunes answer cache. A hit keeps its stored copy; a definite
/// miss keeps only the outcome and time.
public protocol ArtistImageCacheStore: Sendable {
    func artistImageCache(forArtist key: String) async throws -> ArtistImageCacheEntry?
    func saveArtistImageCache(
        _ entry: ArtistImageCacheEntry,
        artwork: StoredArtwork?,
    ) async throws
    /// Removes expired rows and any artwork only they referenced.
    func pruneExpiredArtistImageCache(now: Date) async throws
}

/// The three reads the detail read model composes. The real store is one type.
public protocol EntityDetailStore: EntityLocalReading, ImageOverrideStore, ArtistImageCacheStore {}
