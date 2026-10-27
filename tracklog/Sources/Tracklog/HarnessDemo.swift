import Foundation
import TracklogCore

/// Deterministic content for the harness's surface shots. Droppy never sees
/// this: `host.environment.isHarness` is the only gate.
enum HarnessDemo {
    @MainActor
    static func showNowPlaying(on runtime: CaptureRuntime) async {
        let track = Track(
            title: "Heart of Glass",
            artist: "Blondie",
            album: "Parallel Lines",
            duration: 225,
            bundleID: "com.apple.Music",
        )
        await runtime.ingest(
            MediaSample(
                track: track,
                elapsed: 72,
                playbackRate: 1,
                isPlaying: true,
            ),
        )
    }
}

@MainActor
final class HarnessDemoSource: NowPlayingSource {
    var isAvailable = true

    func start(onSample _: @escaping @MainActor (MediaSample?) -> Void) {}
    func stop() {}
}

actor HarnessDemoStore: ListenStore, AppAllowlistStore, SimpleEditStore, BlockStore {
    private let listens: [Listen]
    private var seenApps: [SeenApp]
    private var simpleEdits: [SimpleEditRule]
    private var blockRules: [BlockRule]

    init() {
        listens = Self.makeListens()
        seenApps = SeededPlayers.bundleIDs.map { SeenApp(bundleID: $0, isAllowed: true) }
            + [SeenApp(bundleID: "com.apple.podcasts", isAllowed: false)]
        simpleEdits = Self.makeSimpleEdits()
        blockRules = Self.makeBlocks()
    }

    func insert(_: Listen) async throws -> Listen? {
        nil
    }

    func page(limit: Int, before cursor: ListenCursor?) async throws -> [Listen] {
        guard let cursor else { return Array(listens.prefix(limit)) }
        guard let index = listens.firstIndex(where: { $0.id == cursor.id }) else { return [] }
        return Array(listens[(index + 1)...].prefix(limit))
    }

    func count() async throws -> Int {
        listens.count
    }

    func apps() async throws -> [SeenApp] {
        seenApps
    }

    func isAllowed(_ bundleID: String) async throws -> Bool {
        seenApps.first { $0.bundleID == bundleID }?.isAllowed ?? false
    }

    @discardableResult
    func recordSeen(_ bundleID: String) async throws -> SeenApp? {
        let normalized = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        if let existing = seenApps.first(where: { $0.bundleID == normalized }) {
            return existing
        }
        let app = SeenApp(bundleID: normalized, isAllowed: false)
        seenApps.append(app)
        return app
    }

    func setAllowed(_ bundleID: String, allowed: Bool) async throws {
        guard let index = seenApps.firstIndex(where: { $0.bundleID == bundleID }) else { return }
        seenApps[index].isAllowed = allowed
    }

    func edits() async throws -> [SimpleEditRule] {
        SimpleEditRule.sortedForApplication(simpleEdits)
    }

    @discardableResult
    func save(_ rule: SimpleEditRule) async throws -> SimpleEditRule {
        if let error = rule.validationError {
            throw error
        }
        let id = rule.id ?? (simpleEdits.map { $0.id ?? 0 }.max() ?? 0) + 1

        // Editing a tuple removes the old row; the tuple itself is the rule's
        // identity, as it is in the real store.
        if let old = simpleEdits.firstIndex(where: { $0.id == id }),
           !Self.sameMatch(simpleEdits[old].match, rule.match) {
            simpleEdits.remove(at: old)
        }

        if let index = simpleEdits.firstIndex(where: { Self.sameMatch($0.match, rule.match) }) {
            let existingID = simpleEdits[index].id ?? id
            let stored = rule.stored(withID: existingID, savedAt: rule.savedAt)
            simpleEdits[index] = stored
            return stored
        }

        let stored = rule.stored(withID: id, savedAt: rule.savedAt)
        simpleEdits.append(stored)
        return stored
    }

    func deleteEdit(id: Int64) async throws {
        simpleEdits.removeAll { $0.id == id }
    }

    private static func sameMatch(_ lhs: SimpleEditRule.Match, _ rhs: SimpleEditRule.Match) -> Bool {
        func normalized(_ value: String?) -> String? {
            value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        return normalized(lhs.track) == normalized(rhs.track)
            && normalized(lhs.artist) == normalized(rhs.artist)
            && normalized(lhs.album) == normalized(rhs.album)
            && normalized(lhs.albumArtist) == normalized(rhs.albumArtist)
    }

    func blocks() async throws -> [BlockRule] {
        BlockRule.sortedForEvaluation(blockRules)
    }

    @discardableResult
    func save(_ block: BlockRule) async throws -> BlockRule {
        if let error = block.validationError {
            throw error
        }
        let id = block.id ?? (blockRules.map { $0.id ?? 0 }.max() ?? 0) + 1

        // Editing a tuple removes the old row; the tuple itself is the block's
        // identity, as it is in the real store.
        if let old = blockRules.firstIndex(where: { $0.id == id }),
           !Self.sameBlock(blockRules[old], block) {
            blockRules.remove(at: old)
        }

        if let index = blockRules.firstIndex(where: { Self.sameBlock($0, block) }) {
            let existingID = blockRules[index].id ?? id
            let stored = block.stored(withID: existingID, savedAt: block.savedAt)
            blockRules[index] = stored
            return stored
        }

        let stored = block.stored(withID: id, savedAt: block.savedAt)
        blockRules.append(stored)
        return stored
    }

    func deleteBlock(id: Int64) async throws {
        blockRules.removeAll { $0.id == id }
    }

    private static func sameBlock(_ lhs: BlockRule, _ rhs: BlockRule) -> Bool {
        normalized(lhs.track) == normalized(rhs.track)
            && normalized(lhs.artist) == normalized(rhs.artist)
            && normalized(lhs.album) == normalized(rhs.album)
            && normalized(lhs.albumArtist) == normalized(rhs.albumArtist)
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func makeBlocks() -> [BlockRule] {
        [
            BlockRule(
                id: 1,
                artist: "The Daily",
                savedAt: Date(timeIntervalSince1970: 1_000_000),
            ),
            BlockRule(
                id: 2,
                track: "Baby Shark",
                savedAt: Date(timeIntervalSince1970: 999_500),
            ),
            BlockRule(
                id: 3,
                album: "Sleep Sounds",
                savedAt: Date(timeIntervalSince1970: 999_000),
            ),
        ]
    }

    private static func makeSimpleEdits() -> [SimpleEditRule] {
        [
            SimpleEditRule(
                id: 1,
                match: .init(track: "Heart of Glass", artist: "Blondie"),
                replacement: .init(album: "Parallel Lines"),
                savedAt: Date(timeIntervalSince1970: 1_000_000),
            ),
            SimpleEditRule(
                id: 2,
                match: .init(album: "Rumours"),
                replacement: .init(album: ""),
                savedAt: Date(timeIntervalSince1970: 999_000),
            ),
            SimpleEditRule(
                id: 3,
                match: .init(artist: "Talking Heads"),
                replacement: .init(album: "Remain in Light (Deluxe)"),
                savedAt: Date(timeIntervalSince1970: 998_000),
            ),
        ]
    }

    private static func makeListens() -> [Listen] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        func at(_ day: Date, _ hour: Int, _ minute: Int) -> Date {
            calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
        }

        let rows = [
            DemoRow(id: 6, title: "Heart of Glass", artist: "Blondie", album: "Parallel Lines", startedAt: at(today, 18, 42)),
            DemoRow(id: 5, title: "Once in a Lifetime", artist: "Talking Heads", album: "Remain in Light", startedAt: at(today, 15, 10)),
            DemoRow(id: 4, title: "Dreams", artist: "Fleetwood Mac", album: "Rumours", startedAt: at(today, 12, 4)),
            DemoRow(id: 3, title: "Teardrop", artist: "Massive Attack", album: "Mezzanine", startedAt: at(today, 9, 26)),
            DemoRow(id: 2, title: "Blue Monday", artist: "New Order", album: "", startedAt: at(yesterday, 21, 18)),
            DemoRow(id: 1, title: "Tainted Love", artist: "Soft Cell", album: "", startedAt: at(yesterday, 19, 2)),
        ]

        return rows.map { row in
            let metadata = ListenMetadata(title: row.title, artist: row.artist, album: row.album)
            return Listen(
                id: row.id,
                raw: metadata,
                processed: metadata,
                bundleID: "com.apple.Music",
                duration: 225,
                playedDuration: 225,
                startedAt: row.startedAt,
                capturedAt: row.startedAt.addingTimeInterval(225),
            )
        }
    }
}

private struct DemoRow {
    let id: Int64
    let title: String
    let artist: String
    let album: String
    let startedAt: Date
}
