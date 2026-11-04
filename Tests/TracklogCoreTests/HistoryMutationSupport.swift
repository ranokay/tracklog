import Foundation
import Testing
@testable import TracklogCore

let mutationBase = Date(timeIntervalSince1970: 1_500_000_000)

@MainActor
func makeMutationRuntime(
    store: any ListenStore,
    credentials: any CredentialStore = MemoryCredentialStore(),
    adapters: [any DeliveryAdapter] = [],
    clock: FakeClock = FakeClock(mutationBase),
    state: TracklogAppState = TracklogAppState(),
    scrobbling: Bool = true,
) -> CaptureRuntime {
    CaptureRuntime(
        state: state,
        clock: clock,
        source: ReplayedNowPlaying(),
        store: store,
        allowlist: InMemoryAppAllowlist(),
        edits: store as? any SimpleEditStore,
        blocks: store as? any BlockStore,
        credentials: credentials,
        serviceAdapters: adapters.map { $0 as any ServiceAdapter },
        settings: CaptureSettings(scrobblingEnabled: scrobbling, nowPlayingEnabled: false),
    )
}

func mutationListen(
    title: String = "Song",
    artist: String = "Artist",
    album: String = "Album",
    albumArtist: String = "Album Artist",
    start: Date = mutationBase,
) -> Listen {
    let metadata = ListenMetadata(
        title: title,
        artist: artist,
        album: album,
        albumArtist: albumArtist,
    )
    return Listen(
        raw: metadata,
        processed: metadata,
        bundleID: "com.apple.Music",
        duration: 200,
        playedDuration: 100,
        startedAt: start,
        capturedAt: start.addingTimeInterval(10),
    )
}

/// A real history read surface whose mutation writes always fail. Used to
/// prove that a failed edit or delete leaves the loaded row and durable row
/// alone and never publishes success.
actor FailingMutationStore: ListenStore, ListenMutationStore {
    private let base: SQLiteListenStore

    init(_ base: SQLiteListenStore) {
        self.base = base
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

    func editListen(
        id _: Int64,
        to _: ListenMetadata,
        remembering _: SimpleEditRule?,
    ) async throws -> ListenEditResult {
        throw DatabaseError.sqlite("simulated edit failure")
    }

    func deleteListen(id _: Int64, at _: Date) async throws {
        throw DatabaseError.sqlite("simulated delete failure")
    }
}
