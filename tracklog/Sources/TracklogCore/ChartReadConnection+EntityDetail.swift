import Foundation
import SQLite3

// MARK: - Entity detail

extension ChartReadConnection {
    // One full scan answers every local field a detail page needs. It is the
    // same normalization the local charts use, so a service row and a local
    // row reach the same page. Top tracks run through the shared aggregator.
    // swiftlint:disable:next cyclomatic_complexity
    func entityLocalDetail(
        kind: EntityKind,
        key: String,
        topTrackLimit: Int,
    ) async throws -> EntityLocalDetail {
        guard !isClosed else {
            throw DatabaseError.open("the chart reader is closed")
        }
        let handle = try openReadOnly()
        defer { sqlite3_close(handle) }

        try execute(handle, "BEGIN DEFERRED")
        do {
            let statement = try prepare(
                handle,
                """
                SELECT title, artist, album, album_artist, artwork_hash, started_at
                FROM listens
                ORDER BY started_at ASC, id ASC
                """,
            )
            defer { sqlite3_finalize(statement) }

            var count = 0
            var first: Date?
            var last: Date?
            var capturedHash: String?
            var aggregator = LocalChartAggregator(type: .tracks)
            var rowIndex = 0
            while true {
                switch sqlite3_step(statement) {
                case SQLITE_ROW:
                    let title = text(statement, 0)
                    let artist = text(statement, 1)
                    let album = text(statement, 2)
                    let albumArtist = text(statement, 3)
                    let startedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))
                    if matches(kind: kind, key: key, title: title, artist: artist, album: album, albumArtist: albumArtist) {
                        count += 1
                        if first == nil {
                            first = startedAt
                        }
                        last = startedAt
                        if capturedHash == nil {
                            capturedHash = sqlite3_column_type(statement, 4) == SQLITE_NULL
                                ? nil
                                : text(statement, 4)
                        }
                        if kind != .track, topTrackLimit > 0 {
                            aggregator.add(
                                title: title,
                                artist: artist,
                                album: album,
                                albumArtist: albumArtist,
                                artworkHash: sqlite3_column_type(statement, 4) == SQLITE_NULL
                                    ? nil
                                    : text(statement, 4),
                            )
                        }
                    }
                    rowIndex += 1
                    if rowIndex % 64 == 0 {
                        try checkOwnership()
                        await Task.yield()
                        try checkOwnership()
                    }
                case SQLITE_DONE:
                    try checkOwnership()
                    try execute(handle, "COMMIT")
                    let topTracks = kind == .track || topTrackLimit <= 0
                        ? []
                        : aggregator.finish(limit: topTrackLimit).items
                    return EntityLocalDetail(
                        count: count,
                        firstListenedAt: first,
                        lastListenedAt: last,
                        topTracks: topTracks,
                        capturedArtworkHash: capturedHash,
                    )
                default:
                    throw DatabaseError.sqlite(errorMessage(handle))
                }
            }
        } catch {
            try? execute(handle, "ROLLBACK")
            throw error
        }
    }

    // swiftlint:disable:next function_parameter_count
    private func matches(
        kind: EntityKind,
        key: String,
        title: String,
        artist: String,
        album: String,
        albumArtist: String,
    ) -> Bool {
        switch kind {
        case .artist:
            return LocalArtistIdentity.key(name: artist) == key
        case .album:
            let subtitle = albumArtist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? artist
                : albumArtist
            return LocalAlbumIdentity.key(album: album, artist: subtitle) == key
        case .track:
            return LocalTrackIdentity.key(title: title, artist: artist) == key
        }
    }
}
