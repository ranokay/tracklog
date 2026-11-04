import Foundation
import TracklogCore

/// A real store whose history pages can be made stale by stripping the
/// artwork hash, simulating a page read that happened before a cover was
/// attached. Everything else delegates to the real SQLite store.
actor StaleArtworkStore: ListenStore, HistoryNavigationStore, ArtworkStore {
    private let base: SQLiteListenStore
    private var stripsArtwork = false

    init(_ base: SQLiteListenStore) {
        self.base = base
    }

    func setStripsArtwork(_ strips: Bool) {
        stripsArtwork = strips
    }

    func insert(_ listen: Listen) async throws -> Listen? {
        try await base.insert(listen)
    }

    func page(limit: Int, before cursor: ListenCursor?) async throws -> [Listen] {
        try await stripped(base.page(limit: limit, before: cursor))
    }

    func count() async throws -> Int {
        try await base.count()
    }

    func count(in range: Range<Date>) async throws -> Int {
        try await base.count(in: range)
    }

    func historyPosition(at date: Date) async throws -> HistoryPosition {
        try await base.historyPosition(at: date)
    }

    func page(limit: Int, endingAt cursor: ListenCursor) async throws -> [Listen] {
        try await stripped(base.page(limit: limit, endingAt: cursor))
    }

    func page(limit: Int, after cursor: ListenCursor) async throws -> [Listen] {
        try await stripped(base.page(limit: limit, after: cursor))
    }

    func hasOlderListen(than cursor: ListenCursor) async throws -> Bool {
        try await base.hasOlderListen(than: cursor)
    }

    func hasNewerListen(than cursor: ListenCursor) async throws -> Bool {
        try await base.hasNewerListen(than: cursor)
    }

    func artwork(for hash: String) async throws -> Data? {
        try await base.artwork(for: hash)
    }

    func artworkHash(forTrack identity: String) async throws -> String? {
        try await base.artworkHash(forTrack: identity)
    }

    func attachArtwork(_ artwork: StoredArtwork, toTrack identity: String) async throws {
        try await base.attachArtwork(artwork, toTrack: identity)
    }

    private func stripped(_ listens: [Listen]) -> [Listen] {
        guard stripsArtwork else { return listens }
        return listens.map { $0.withArtworkHash(nil) }
    }
}
