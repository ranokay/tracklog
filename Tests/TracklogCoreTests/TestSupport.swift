import Foundation
import SQLite3
@testable import TracklogCore

/// A scratch container with one database file, removed when the test ends.
final class TemporaryDatabase {
    let directory: URL
    let url: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tracklog-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("tracklog.sqlite")
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func backupCount() -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasPrefix("tracklog-backup-") }.count
    }

    func userVersion() throws -> Int {
        try withSQLite { handle in
            try queryInt(handle, "PRAGMA user_version")
        }
    }

    func setUserVersion(_ version: Int) throws {
        try withSQLite { handle in
            try SQLiteListenStore.execute(handle, "PRAGMA user_version = \(version)")
        }
    }

    func hasColumn(_ column: String, in table: String) throws -> Bool {
        try withSQLite { handle in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK,
                  let statement
            else {
                throw DatabaseError.sqlite("could not read table info")
            }
            defer { sqlite3_finalize(statement) }
            while sqlite3_step(statement) == SQLITE_ROW {
                if let name = sqlite3_column_text(statement, 1), String(cString: name) == column {
                    return true
                }
            }
            return false
        }
    }

    func readData() throws -> Data {
        try Data(contentsOf: url)
    }

    func write(_ data: Data) throws {
        try data.write(to: url)
    }

    private func withSQLite<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let handle else {
            throw DatabaseError.open("could not open \(url.path)")
        }
        defer { sqlite3_close(handle) }
        return try body(handle)
    }

    private func queryInt(_ handle: OpaquePointer, _ sql: String) throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw DatabaseError.sqlite("could not prepare \(sql)")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw DatabaseError.sqlite("no row for \(sql)")
        }
        return Int(sqlite3_column_int(statement, 0))
    }
}

@MainActor
final class FakeClock: Clock {
    var now: Date

    init(_ now: Date) {
        self.now = now
    }

    func sleep(until _: Date) async throws {}
}

@MainActor
final class ReplayedNowPlaying: NowPlayingSource {
    var isAvailable = true
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var handler: ((MediaSample?) -> Void)?

    func start(onSample: @escaping @MainActor (MediaSample?) -> Void) {
        startCount += 1
        handler = onSample
    }

    func stop() {
        stopCount += 1
        handler = nil
    }
}

/// Fixtures shared by the capture suites. A dedicated track plays for thirty
/// seconds of two-second samples, enough to cross the engine's threshold.
@MainActor
protocol CaptureTestHelpers {}

extension CaptureTestHelpers {
    var base: Date {
        Date(timeIntervalSince1970: 1_000_000)
    }

    func track(
        title: String = "Song",
        artist: String = "Artist",
        album: String = "Album",
        albumArtist: String = "Album Artist",
        duration: TimeInterval = 30,
        bundleID: String = "com.apple.Music",
    ) -> Track {
        Track(
            title: title,
            artist: artist,
            album: album,
            albumArtist: albumArtist,
            duration: duration,
            bundleID: bundleID,
        )
    }

    func sample(
        _ track: Track,
        at offset: TimeInterval,
        elapsed: TimeInterval,
        playing: Bool = true,
    ) -> MediaSample {
        MediaSample(
            track: track,
            elapsed: elapsed,
            playbackRate: playing ? 1 : 0,
            isPlaying: playing,
            timestamp: base.addingTimeInterval(offset),
        )
    }

    func thresholdSamples(_ track: Track, offset: TimeInterval = 0) -> [MediaSample] {
        stride(from: 0.0, through: 30.0, by: 2.0).map { second in
            sample(track, at: offset + second, elapsed: second)
        }
    }

    func runtime(
        database: TemporaryDatabase,
        clock: FakeClock,
        source: ReplayedNowPlaying,
        enabled: Bool = true,
        persistScrobbling: (@MainActor (Bool) -> Void)? = nil,
    ) -> CaptureRuntime {
        CaptureRuntime.open(
            databaseURL: database.url,
            clock: clock,
            source: source,
            scrobblingEnabled: enabled,
            persistScrobbling: persistScrobbling,
        )
    }

    func replay(
        _ samples: [MediaSample],
        on runtime: CaptureRuntime,
        clock: FakeClock,
    ) async {
        for sample in samples {
            clock.now = sample.timestamp
            await runtime.ingest(sample)
        }
    }

    func listen(title: String, start: TimeInterval) -> Listen {
        Listen(
            raw: ListenMetadata(title: title, artist: "Artist"),
            processed: ListenMetadata(title: title, artist: "Artist"),
            bundleID: "com.apple.Music",
            duration: 200,
            playedDuration: 100,
            startedAt: base.addingTimeInterval(start),
            capturedAt: base.addingTimeInterval(start),
        )
    }
}
