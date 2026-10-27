import Foundation
import Testing
@testable import TracklogCore

@Suite("History day counts")
@MainActor
struct HistoryDayCountTests: CaptureTestHelpers {
    @Test func dayCountsCoverAWholeDayAcrossPages() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: base)
        let noon = try #require(calendar.date(bySettingHour: 12, minute: 0, second: 0, of: day))
        for index in 0 ..< 150 {
            _ = try await store.insert(
                listen(
                    title: "Song \(index)",
                    start: noon.timeIntervalSince(base) + TimeInterval(index),
                ),
            )
        }

        let runtime = CaptureRuntime(
            clock: FakeClock(base),
            source: ReplayedNowPlaying(),
            store: store,
            scrobblingEnabled: false,
            historyPageSize: 100,
        )
        await runtime.start()

        #expect(runtime.state.listens.count == 100)
        #expect(runtime.state.historyCount == 150)
        #expect(runtime.state.historyHasMore)
        #expect(runtime.state.historyDayCounts[day] == 150)

        await runtime.loadMoreHistory()

        #expect(runtime.state.listens.count == 150)
        #expect(runtime.state.historyHasMore == false)
        #expect(runtime.state.historyDayCounts[day] == 150)
    }
}
