import Foundation
import TracklogCore

/// The History states the harness renders. Production never reads this: the
/// environment override is gated by `host.environment.isHarness`.
enum HarnessHistoryFixture: String {
    case empty
    case large
    case track
    case trackMissingArtwork = "track-missing-artwork"
    case jump
    case trackError = "track-error"
    case feedError = "feed-error"
    case settingsRefused = "settings-refused"
    static var selected: HarnessHistoryFixture? {
        guard let raw = ProcessInfo.processInfo.environment["TRACKLOG_HARNESS_HISTORY"] else {
            return nil
        }
        return HarnessHistoryFixture(rawValue: raw)
    }

    var failsFeedReads: Bool {
        self == .feedError
    }

    var failsTrackReads: Bool {
        self == .trackError
    }
}

enum HarnessHistoryDemo {
    /// Deterministic extra rows for the history fixtures. They extend the base
    /// demo content rather than replacing it, so every state keeps the covers,
    /// delivery states and the playing strip.
    static func listens(
        for fixture: HarnessHistoryFixture?,
        content: HarnessDemoData.DemoContent,
    ) -> [Listen] {
        guard let fixture else { return content.listens }
        switch fixture {
        case .empty:
            return []
        case .large:
            return merged(
                content.listens,
                archiveListens(count: 250, content: content),
            )
        case .track:
            return merged(
                content.listens,
                trackListens(
                    title: "Heart of Glass",
                    artist: "Blondie",
                    album: "Parallel Lines",
                    count: 74,
                    content: content,
                ),
            )
        case .trackMissingArtwork:
            return merged(
                content.listens,
                trackListens(
                    title: "Blue Monday",
                    artist: "New Order",
                    album: "",
                    count: 44,
                    content: content,
                ),
            )
        case .jump, .trackError, .feedError, .settingsRefused:
            return content.listens
        }
    }

    @MainActor
    static func show(on runtime: CaptureRuntime) async {
        guard let fixture = HarnessHistoryFixture.selected else { return }
        runtime.state.setPendingListExpanded(false)
        switch fixture {
        case .empty, .large, .feedError:
            break
        case .settingsRefused:
            runtime.state.setHistorySettingsUnavailable(true)
        case .jump:
            await runtime.jumpHistory(to: jumpDate())
        case .track, .trackError:
            if let row = runtime.state.listens.first(where: { $0.processed.title == "Heart of Glass" }) {
                await runtime.openTrackHistory(row)
            }
        case .trackMissingArtwork:
            if let row = runtime.state.listens.first(where: { $0.processed.title == "Blue Monday" }) {
                await runtime.openTrackHistory(row)
            }
        }
    }

    static func jumpDate(now: Date = Date()) -> Date {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        return calendar.date(bySettingHour: 20, minute: 0, second: 0, of: yesterday) ?? yesterday
    }

    private static func merged(_ base: [Listen], _ extra: [Listen]) -> [Listen] {
        (base + extra).sorted { lhs, rhs in
            if lhs.startedAt != rhs.startedAt {
                return lhs.startedAt > rhs.startedAt
            }
            return (lhs.id ?? 0) > (rhs.id ?? 0)
        }
    }

    private static func archiveListens(
        count: Int,
        content: HarnessDemoData.DemoContent,
    ) -> [Listen] {
        let now = Date()
        let covers = Array(content.artworks.keys).sorted()
        return (0 ..< count).map { index in
            let metadata = ListenMetadata(
                title: "Archive Song \(index + 1)",
                artist: "Various Artists",
                album: "Archive",
            )
            let artworkHash = covers.isEmpty ? nil : covers[index % covers.count]
            let start = now.addingTimeInterval(-Double(index + 1) * 3 * 60 * 60)
            return Listen(
                id: Int64(1_000 + index),
                raw: metadata,
                processed: metadata,
                bundleID: index.isMultiple(of: 2) ? "com.apple.Music" : "com.spotify.client",
                duration: 210,
                playedDuration: 210,
                startedAt: start,
                capturedAt: start.addingTimeInterval(210),
                artworkHash: artworkHash,
            )
        }
    }

    private static func trackListens(
        title: String,
        artist: String,
        album: String,
        count: Int,
        content: HarnessDemoData.DemoContent,
    ) -> [Listen] {
        let metadata = ListenMetadata(title: title, artist: artist, album: album)
        let artworkHash = content.hashes[metadata.identity]
        let now = Date()
        return (0 ..< count).map { index in
            let start = now.addingTimeInterval(-Double(index + 1) * 5 * 60 * 60)
            return Listen(
                id: Int64(2_000 + index),
                raw: metadata,
                processed: metadata,
                bundleID: index.isMultiple(of: 2) ? "com.apple.Music" : "com.spotify.client",
                duration: 225,
                playedDuration: 225,
                startedAt: start,
                capturedAt: start.addingTimeInterval(225),
                artworkHash: artworkHash,
            )
        }
    }
}

extension HarnessDemoStore: HistoryNavigationStore, TrackHistoryStore {
    func historyPosition(at date: Date) async throws -> HistoryPosition {
        try checkFeedReads()
        let candidates = listens
            .filter { $0.startedAt >= date }
            .sorted { lhs, rhs in
                if lhs.startedAt != rhs.startedAt {
                    return lhs.startedAt < rhs.startedAt
                }
                return (lhs.id ?? 0) < (rhs.id ?? 0)
            }
        guard let firstStart = candidates.first?.startedAt, let anchor = candidates.last(where: { $0.startedAt == firstStart }) else {
            return .newest
        }
        return .atCursor(ListenCursor(startedAt: anchor.startedAt, id: anchor.id ?? 0))
    }

    func page(limit: Int, endingAt cursor: ListenCursor) async throws -> [Listen] {
        try checkFeedReads()
        guard limit > 0 else { return [] }
        return Array(
            listens
                .filter {
                    $0.startedAt < cursor.startedAt
                        || ($0.startedAt == cursor.startedAt && ($0.id ?? 0) <= cursor.id)
                }
                .prefix(limit),
        )
    }

    func page(limit: Int, after cursor: ListenCursor) async throws -> [Listen] {
        try checkFeedReads()
        guard limit > 0 else { return [] }
        let newer = listens
            .filter {
                $0.startedAt > cursor.startedAt
                    || ($0.startedAt == cursor.startedAt && ($0.id ?? 0) > cursor.id)
            }
            .sorted { lhs, rhs in
                if lhs.startedAt != rhs.startedAt {
                    return lhs.startedAt < rhs.startedAt
                }
                return (lhs.id ?? 0) < (rhs.id ?? 0)
            }
            .prefix(limit)
        return Array(newer.reversed())
    }

    func hasOlderListen(than cursor: ListenCursor) async throws -> Bool {
        try checkFeedReads()
        return listens.contains {
            $0.startedAt < cursor.startedAt
                || ($0.startedAt == cursor.startedAt && ($0.id ?? 0) < cursor.id)
        }
    }

    func hasNewerListen(than cursor: ListenCursor) async throws -> Bool {
        try checkFeedReads()
        return listens.contains {
            $0.startedAt > cursor.startedAt
                || ($0.startedAt == cursor.startedAt && ($0.id ?? 0) > cursor.id)
        }
    }

    func trackHistorySummary(matching key: String) async throws -> TrackHistorySummary {
        try checkTrackReads()
        let matches = listens.filter {
            LocalTrackIdentity.key(
                title: $0.processed.title,
                artist: $0.processed.artist,
            ) == key
        }
        return TrackHistorySummary(
            count: matches.count,
            firstListenedAt: matches.map(\.startedAt).min(),
        )
    }

    func trackHistoryPage(
        matching key: String,
        limit: Int,
        before cursor: ListenCursor?,
    ) async throws -> [Listen] {
        try checkTrackReads()
        guard limit > 0 else { return [] }
        let matching = listens.filter {
            LocalTrackIdentity.key(
                title: $0.processed.title,
                artist: $0.processed.artist,
            ) == key
        }
        let older = if let cursor {
            matching.filter {
                $0.startedAt < cursor.startedAt
                    || ($0.startedAt == cursor.startedAt && ($0.id ?? 0) < cursor.id)
            }
        } else {
            matching
        }
        return Array(older.prefix(limit))
    }

    func checkFeedReads() throws {
        guard historyFixture?.failsFeedReads != true else {
            throw DatabaseError.sqlite("simulated history read failure")
        }
    }

    private func checkTrackReads() throws {
        guard historyFixture?.failsTrackReads != true else {
            throw DatabaseError.sqlite("simulated track history read failure")
        }
    }
}
