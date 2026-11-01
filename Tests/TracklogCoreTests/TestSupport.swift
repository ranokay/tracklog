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

    /// Inserts a row the way a build before artwork support wrote one. The
    /// current store's insert names artwork columns, which a v1-v4 schema does
    /// not have; migration tests still need a pre-upgrade history row.
    @discardableResult
    func insertLegacyListen(_ listen: Listen) throws -> Listen {
        try withSQLite { handle in
            var statement: OpaquePointer?
            let sql = """
            INSERT INTO listens (
                raw_title, raw_artist, raw_album, raw_album_artist,
                title, artist, album, album_artist,
                bundle_id, duration, played_duration, started_at, captured_at, dedup_key
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
                  let statement
            else {
                throw DatabaseError.sqlite("could not prepare a legacy listen insert")
            }
            defer { sqlite3_finalize(statement) }

            let fields = [
                listen.raw.title, listen.raw.artist, listen.raw.album, listen.raw.albumArtist,
                listen.processed.title, listen.processed.artist, listen.processed.album,
                listen.processed.albumArtist, listen.bundleID,
            ]
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for (offset, value) in fields.enumerated() {
                guard sqlite3_bind_text(statement, Int32(offset + 1), value, -1, transient) == SQLITE_OK else {
                    throw DatabaseError.sqlite("could not bind a legacy listen value")
                }
            }
            sqlite3_bind_double(statement, 10, listen.duration)
            sqlite3_bind_double(statement, 11, listen.playedDuration)
            sqlite3_bind_double(statement, 12, listen.startedAt.timeIntervalSince1970)
            sqlite3_bind_double(statement, 13, listen.capturedAt.timeIntervalSince1970)
            guard sqlite3_bind_text(statement, 14, listen.dedupKey, -1, transient) == SQLITE_OK,
                  sqlite3_step(statement) == SQLITE_DONE
            else {
                throw DatabaseError.sqlite("could not insert a legacy listen")
            }
            return listen.stored(withID: sqlite3_last_insert_rowid(handle))
        }
    }

    func write(_ data: Data) throws {
        try data.write(to: url)
    }

    func execute(_ sql: String) throws {
        try withSQLite { handle in
            try SQLiteListenStore.execute(handle, sql)
        }
    }

    /// Inserts a delivery the way a build before unlink support wrote one,
    /// when the table had no denormalized service kind.
    func insertLegacyDelivery(listenID: Int64, connectionID: Int64, state: String = "waiting") throws {
        try withSQLite { handle in
            try SQLiteListenStore.execute(
                handle,
                """
                INSERT INTO deliveries (listen_id, connection_id, state, attempts, next_attempt_at)
                VALUES (\(listenID), \(connectionID), '\(state)', 0, 1000000)
                """,
            )
        }
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
    private struct Sleeper {
        let until: Date
        let continuation: CheckedContinuation<Void, Error>
    }

    private var sleepers: [UUID: Sleeper] = [:]

    var now: Date {
        didSet { wakeSleepers() }
    }

    init(_ now: Date) {
        self.now = now
    }

    /// Moves time forward, waking every sleeper whose deadline has passed.
    func advance(to date: Date) {
        now = max(now, date)
    }

    /// The tasks currently waiting on this clock. Tests use it to advance only
    /// after the code under test has registered its next sleep.
    var sleeperCount: Int {
        sleepers.count
    }

    func sleep(until date: Date) async throws {
        guard date > now else { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                sleepers[id] = Sleeper(until: date, continuation: continuation)
                // The clock may have moved between the guard and here.
                wakeSleepers()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelSleeper(id)
            }
        }
    }

    private func wakeSleepers() {
        let ready = sleepers.filter { $0.value.until <= now }.map(\.key)
        for id in ready {
            guard let sleeper = sleepers.removeValue(forKey: id) else { continue }
            sleeper.continuation.resume()
        }
    }

    private func cancelSleeper(_ id: UUID) {
        guard let sleeper = sleepers.removeValue(forKey: id) else { return }
        sleeper.continuation.resume(throwing: CancellationError())
    }
}

/// The allowlist the capture tests drive. Music and Spotify start allowed, the
/// way a new database seeds them.
actor InMemoryAppAllowlist: AppAllowlistStore {
    private var recorded: [SeenApp]

    init(allowed: [String] = SeededPlayers.bundleIDs) {
        recorded = allowed.map { SeenApp(bundleID: $0, isAllowed: true) }
    }

    func apps() async throws -> [SeenApp] {
        recorded
    }

    func isAllowed(_ bundleID: String) async throws -> Bool {
        recorded.first { $0.bundleID == bundleID }?.isAllowed ?? false
    }

    @discardableResult
    func recordSeen(_ bundleID: String) async throws -> SeenApp? {
        let normalized = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        if let existing = recorded.first(where: { $0.bundleID == normalized }) {
            return existing
        }
        let app = SeenApp(bundleID: normalized, isAllowed: false)
        recorded.append(app)
        return app
    }

    func setAllowed(_ bundleID: String, allowed: Bool) async throws {
        guard let index = recorded.firstIndex(where: { $0.bundleID == bundleID }) else { return }
        recorded[index].isAllowed = allowed
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
        settings: CaptureSettings? = nil,
        persistSettings: (@MainActor (CaptureSettings) -> Void)? = nil,
        sendNowPlaying: (@MainActor (Track) -> Void)? = nil,
    ) -> CaptureRuntime {
        CaptureRuntime.open(
            databaseURL: database.url,
            clock: clock,
            source: source,
            settings: settings ?? CaptureSettings(scrobblingEnabled: enabled),
            persistSettings: persistSettings,
            sendNowPlaying: sendNowPlaying,
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

    /// Pumps the main actor until `condition` holds. The pause's deadline is
    /// driven by `FakeClock`, so a test advances the clock and then lets the
    /// expiry task run.
    func yieldUntil(
        _ condition: @MainActor () -> Bool,
        rounds: Int = 200,
    ) async {
        for _ in 0 ..< rounds {
            if condition() {
                return
            }
            await Task.yield()
        }
    }

    /// Waits for work that hops off the main actor, such as artwork
    /// normalization, without sleeping for a fixed interval in every test.
    func eventually(
        timeout: Duration = .seconds(3),
        _ condition: @MainActor () -> Bool,
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if condition() {
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
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

/// A simple-edit fixture shared by the metadata, store and capture suites.
func simpleEditRule(
    id: Int64? = nil,
    match: SimpleEditRule.Match = .init(),
    replace: SimpleEditRule.Replacement = .init(),
    savedAt: Date = Date(timeIntervalSince1970: 1_000_000),
) -> SimpleEditRule {
    SimpleEditRule(id: id, match: match, replacement: replace, savedAt: savedAt)
}

/// A block fixture shared by the metadata, store and capture suites.
func blockRule(
    id: Int64? = nil,
    track: String = "",
    artist: String = "",
    album: String = "",
    albumArtist: String = "",
    savedAt: Date = Date(timeIntervalSince1970: 1_000_000),
) -> BlockRule {
    BlockRule(
        id: id,
        track: track,
        artist: artist,
        album: album,
        albumArtist: albumArtist,
        savedAt: savedAt,
    )
}
