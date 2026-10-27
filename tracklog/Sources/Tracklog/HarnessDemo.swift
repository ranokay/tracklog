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

actor HarnessDemoStore: ListenStore {
    private let listens: [Listen]

    init() {
        listens = Self.makeListens()
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
