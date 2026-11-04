import Foundation
import Testing
@testable import TracklogCore

let historyBase = Date(timeIntervalSince1970: 1_500_000_000)

func historyListen(
    title: String,
    artist: String = "Artist",
    album: String = "",
    bundleID: String = "com.apple.Music",
    start: Date,
) -> Listen {
    let metadata = ListenMetadata(title: title, artist: artist, album: album)
    return Listen(
        raw: metadata,
        processed: metadata,
        bundleID: bundleID,
        duration: 200,
        playedDuration: 200,
        startedAt: start,
        capturedAt: start.addingTimeInterval(200),
    )
}

@MainActor
func historyRuntime(
    store: any ListenStore,
    state: TracklogAppState = TracklogAppState(),
    pageSize: Int = 50,
    clock: FakeClock = FakeClock(historyBase),
    scrobbling: Bool = false,
) -> CaptureRuntime {
    CaptureRuntime(
        state: state,
        clock: clock,
        source: ReplayedNowPlaying(),
        store: store,
        allowlist: InMemoryAppAllowlist(),
        settings: CaptureSettings(scrobblingEnabled: scrobbling),
        historyPageSize: pageSize,
    )
}

func seedHistory(
    _ store: SQLiteListenStore,
    count: Int,
    start: Date = historyBase,
) async throws {
    for index in 0 ..< count {
        _ = try await store.insert(
            historyListen(
                title: "Song \(index)",
                start: start.addingTimeInterval(Double(index) * 60),
            ),
        )
    }
}

/// Replays a threshold-crossing session at a chosen wall-clock time. The
/// shared helper's `base` is 1970, which would put captured listens before the
/// fixtures this suite seeds.
@MainActor
func replayThreshold(
    _ track: Track,
    at date: Date,
    on runtime: CaptureRuntime,
    clock: FakeClock,
) async {
    for second in stride(from: 0.0, through: 30.0, by: 2.0) {
        let timestamp = date.addingTimeInterval(second)
        clock.now = timestamp
        await runtime.ingest(
            MediaSample(
                track: track,
                elapsed: second,
                playbackRate: 1,
                isPlaying: true,
                timestamp: timestamp,
            ),
        )
    }
}

// MARK: - Failure helper

/// A real store whose track-history reads fail a fixed number of times. Every
/// other read and every write still reaches SQLite, so a test can prove a
/// track failure does not touch capture.
actor FailingTrackHistoryStore: ListenStore, TrackHistoryStore, EntityDetailStore {
    private let base: SQLiteListenStore
    private var failuresRemaining: Int

    init(_ base: SQLiteListenStore, failures: Int) {
        self.base = base
        failuresRemaining = failures
    }

    func insert(_ listen: Listen) async throws -> Listen? {
        try await base.insert(listen)
    }

    func page(limit: Int, before cursor: ListenCursor?) async throws -> [Listen] {
        try await base.page(limit: limit, before: cursor)
    }

    func count() async throws -> Int {
        try await base.count()
    }

    func count(in range: Range<Date>) async throws -> Int {
        try await base.count(in: range)
    }

    func entityLocalDetail(
        kind: EntityKind,
        key: String,
        topTrackLimit: Int,
    ) async throws -> EntityLocalDetail {
        guard failuresRemaining == 0 else {
            failuresRemaining -= 1
            throw DatabaseError.sqlite("simulated track history read failure")
        }
        return try await base.entityLocalDetail(
            kind: kind,
            key: key,
            topTrackLimit: topTrackLimit,
        )
    }

    func imageOverrides() async throws -> [ImageOverride] {
        try await base.imageOverrides()
    }

    func imageOverride(kind: EntityKind, key: String) async throws -> ImageOverride? {
        try await base.imageOverride(kind: kind, key: key)
    }

    func saveImageOverride(_ override: ImageOverride, artwork: StoredArtwork) async throws {
        try await base.saveImageOverride(override, artwork: artwork)
    }

    func removeImageOverride(kind: EntityKind, key: String) async throws {
        try await base.removeImageOverride(kind: kind, key: key)
    }

    func artistImageCache(forArtist key: String) async throws -> ArtistImageCacheEntry? {
        try await base.artistImageCache(forArtist: key)
    }

    func saveArtistImageCache(
        _ entry: ArtistImageCacheEntry,
        artwork: StoredArtwork?,
    ) async throws {
        try await base.saveArtistImageCache(entry, artwork: artwork)
    }

    func pruneExpiredArtistImageCache(now: Date) async throws {
        try await base.pruneExpiredArtistImageCache(now: now)
    }

    func trackHistorySummary(matching key: String) async throws -> TrackHistorySummary {
        guard failuresRemaining == 0 else {
            failuresRemaining -= 1
            throw DatabaseError.sqlite("simulated track history read failure")
        }
        return try await base.trackHistorySummary(matching: key)
    }

    func trackHistoryPage(
        matching key: String,
        limit: Int,
        before cursor: ListenCursor?,
    ) async throws -> [Listen] {
        try await base.trackHistoryPage(matching: key, limit: limit, before: cursor)
    }
}
