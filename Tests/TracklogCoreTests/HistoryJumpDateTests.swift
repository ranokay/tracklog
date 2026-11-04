import Foundation
import Testing
@testable import TracklogCore

@Suite("History jump date")
@MainActor
struct HistoryJumpDateTests {
    @Test func aPickerMinuteStartIgnoresHiddenSeconds() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: historyBase)
        let midnight = try #require(calendar.date(byAdding: .day, value: 1, to: day))
        _ = try await store.insert(
            historyListen(title: "Just after midnight", start: midnight.addingTimeInterval(10)),
        )
        _ = try await store.insert(
            historyListen(title: "Later", start: midnight.addingTimeInterval(90)),
        )

        let state = TracklogAppState()
        let runtime = historyRuntime(store: store, state: state)
        await runtime.start()

        // A minute-resolution picker can carry the seconds of its initial
        // value. The chosen minute is 00:00, so the 00:00:10 listen is the
        // position even when the picked date holds 37 hidden seconds.
        let picked = midnight.addingTimeInterval(37)
        let instant = HistoryJumpDate.minuteStart(picked)
        #expect(instant == midnight)
        await runtime.jumpHistory(to: instant)
        #expect(state.listens.first?.processed.title == "Just after midnight")

        await runtime.jumpHistory(to: picked)
        #expect(state.listens.first?.processed.title == "Later",
                "without the minute start the hidden seconds skip the first listen")
    }
}
