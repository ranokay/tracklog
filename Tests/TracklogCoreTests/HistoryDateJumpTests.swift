import Foundation
import Testing
@testable import TracklogCore

// MARK: - Date jump

@Suite("History date jump")
@MainActor
struct HistoryDateJumpTests: CaptureTestHelpers {
    @Test func aJumpStartsAtTheFirstListenAndPagesBothWays() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        try await seedHistory(store, count: 250)
        let state = TracklogAppState()
        let runtime = historyRuntime(store: store, state: state)
        await runtime.start()
        #expect(state.listens.count == 50)

        let target = historyBase.addingTimeInterval(120 * 60 + 30)
        await runtime.jumpHistory(to: target)

        #expect(state.listens.first?.startedAt == historyBase.addingTimeInterval(121 * 60))
        #expect(state.listens.count == 50)
        #expect(state.historyCount == 250)
        #expect(state.historyHasMore)
        #expect(state.historyHasNewer)
        #expect(state.historyJumpNotice?.kind == .positioned)
        #expect(state.pendingHistoryJump == nil)
        let anchorID = try #require(state.listens.first?.id)

        var olderLoads = 0
        while state.historyHasMore, olderLoads < 20 {
            await runtime.loadMoreHistory()
            olderLoads += 1
        }
        #expect(olderLoads == 2, "122 older rows load in 50 + 50 + 22")
        #expect(state.listens.count == 122)
        #expect(state.listens.last?.startedAt == historyBase)
        #expect(!state.historyHasMore, "reaching the oldest row reports no more")
        #expect(state.historyHasNewer)

        var newerLoads = 0
        while state.historyHasNewer, newerLoads < 20 {
            await runtime.loadNewerHistory()
            newerLoads += 1
        }
        #expect(newerLoads == 3, "128 newer rows load in 50 + 50 + 28")
        #expect(state.listens.count == 250)
        #expect(state.listens.first?.startedAt == historyBase.addingTimeInterval(249 * 60))
        #expect(state.listens.contains { $0.id == anchorID }, "the jump anchor stays loaded")
        #expect(Set(state.listens.compactMap(\.id)).count == 250)
        #expect(!state.historyHasNewer)
        #expect(!state.historyHasMore)
        #expect(state.historyJumpNotice == nil, "reaching the live top ends the jump")
    }

    @Test func aMidnightJumpStartsAtTheFirstListenOfTheNewDay() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: historyBase)
        let late = day.addingTimeInterval(86_399)
        let midnight = try #require(calendar.date(byAdding: .day, value: 1, to: day))
        _ = try await store.insert(historyListen(title: "Late", start: late))
        _ = try await store.insert(historyListen(title: "Midnight", start: midnight))
        _ = try await store.insert(historyListen(title: "Next", start: midnight.addingTimeInterval(60)))

        let state = TracklogAppState()
        let runtime = historyRuntime(store: store, state: state)
        await runtime.start()

        await runtime.jumpHistory(to: midnight)
        #expect(state.listens.first?.processed.title == "Midnight")
        #expect(state.historyJumpNotice?.kind == .positioned)

        await runtime.jumpHistory(to: late)
        #expect(state.listens.first?.processed.title == "Late")

        await runtime.jumpHistory(to: late.addingTimeInterval(-60))
        #expect(state.listens.first?.processed.title == "Late")
    }

    @Test func aMissingDayNamesTheDayAndShowsTheNextListen() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let calendar = Calendar.current
        let day0 = calendar.startOfDay(for: historyBase)
        let day1 = try #require(calendar.date(byAdding: .day, value: 1, to: day0))
        let day2 = try #require(calendar.date(byAdding: .day, value: 2, to: day0))
        _ = try await store.insert(
            historyListen(title: "Day zero", start: day0.addingTimeInterval(12 * 60 * 60)),
        )
        _ = try await store.insert(
            historyListen(title: "Day two", start: day2.addingTimeInterval(12 * 60 * 60)),
        )

        let state = TracklogAppState()
        let runtime = historyRuntime(store: store, state: state)
        await runtime.start()

        await runtime.jumpHistory(to: day1.addingTimeInterval(12 * 60 * 60))
        #expect(state.listens.first?.processed.title == "Day two")
        #expect(state.historyJumpNotice?.kind == .emptyDay)
        #expect(!state.historyHasNewer, "day two is the newest row")

        await runtime.jumpHistory(to: day2.addingTimeInterval(5 * 24 * 60 * 60))
        #expect(state.listens.first?.processed.title == "Day two")
        #expect(state.historyJumpNotice?.kind == .afterNewest)
        #expect(!state.historyHasNewer)

        await runtime.jumpHistory(to: day0.addingTimeInterval(-2 * 24 * 60 * 60))
        #expect(state.listens.first?.processed.title == "Day zero")
        #expect(state.historyJumpNotice?.kind == .emptyDay)
    }

    @Test func anEmptyHistoryShowsNoJumpNotice() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let state = TracklogAppState()
        let runtime = historyRuntime(store: store, state: state)
        await runtime.start()

        await runtime.jumpHistory(to: historyBase)

        #expect(state.listens.isEmpty)
        #expect(state.historyCount == 0)
        #expect(state.historyJumpNotice == nil)
        #expect(!state.historyHasMore)
        #expect(!state.historyHasNewer)
    }

    @Test func timestampTiesCrossNewerPagesExactlyOnce() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let base = historyBase
        _ = try await store.insert(historyListen(title: "Anchor", start: base))
        for index in 0 ..< 5 {
            _ = try await store.insert(
                historyListen(title: "Older tie \(index)", start: base + 10),
            )
        }
        for index in 0 ..< 5 {
            _ = try await store.insert(
                historyListen(title: "Newer tie \(index)", start: base + 20),
            )
        }
        _ = try await store.insert(historyListen(title: "Top", start: base + 30))

        let state = TracklogAppState()
        let runtime = historyRuntime(store: store, state: state, pageSize: 3)
        await runtime.start()
        await runtime.jumpHistory(to: base)

        #expect(state.listens.map(\.processed.title) == ["Anchor"])
        #expect(state.historyHasNewer)
        var loads = 0
        while state.historyHasNewer, loads < 20 {
            await runtime.loadNewerHistory()
            loads += 1
        }

        #expect(state.listens.count == 12)
        #expect(Set(state.listens.compactMap(\.id)).count == 12)
        for startedAt in Set(state.listens.map(\.startedAt)) {
            let ids = state.listens.filter { $0.startedAt == startedAt }.compactMap(\.id)
            #expect(ids == ids.sorted(by: >), "ties stay in stored descending order")
        }
        #expect(state.listens.first?.processed.title == "Top")
        #expect(!state.historyHasNewer)
        #expect(state.historyJumpNotice == nil)
    }

    @Test func aCaptureDoesNotMoveAJumpedWindow() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let base = base
        for index in 0 ..< 10 {
            _ = try await store.insert(
                historyListen(
                    title: "Seeded \(index)",
                    start: base.addingTimeInterval(-600 + Double(index) * 60),
                ),
            )
        }
        let clock = FakeClock(base)
        let state = TracklogAppState()
        let runtime = historyRuntime(
            store: store,
            state: state,
            clock: clock,
            scrobbling: true,
        )
        await runtime.start()
        await runtime.jumpHistory(to: base.addingTimeInterval(-300))
        let anchorID = try #require(state.listens.first?.id)

        await replay(
            thresholdSamples(track(title: "Fresh", artist: "Artist", album: "Album")),
            on: runtime,
            clock: clock,
        )
        await eventually { state.listenCount == 1 }

        #expect(state.historyCount == 11)
        #expect(state.listens.first?.id == anchorID, "the jumped window does not move")
        #expect(!state.listens.contains { $0.processed.title == "Fresh" })

        await runtime.reloadHistory()
        #expect(state.listens.first?.processed.title == "Fresh")
    }

    @Test func aPendingJumpSurvivesANavigationResetButNotARestart() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        try await seedHistory(store, count: 5)
        let state = TracklogAppState()
        let runtime = historyRuntime(store: store, state: state)
        await runtime.start()
        let target = historyBase.addingTimeInterval(2 * 60)

        state.requestHistoryJump(target)
        runtime.resetHistoryNavigation()
        #expect(state.pendingHistoryJump == target,
                "a refused or interrupted presentation is retried on the next open")

        runtime.stop()
        #expect(state.pendingHistoryJump == nil, "restart discards the one-shot request")
    }

    @Test func aFailedJumpKeepsTheLoadedFeed() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        try await seedHistory(store, count: 5)
        let state = TracklogAppState()
        let runtime = historyRuntime(store: store, state: state)
        await runtime.start()
        let loaded = state.listens
        await store.close()

        await runtime.jumpHistory(to: historyBase)

        #expect(state.listens == loaded)
        #expect(state.historyFailure != nil)
        #expect(state.failure?.stage == .history)
        #expect(state.historyJumpNotice == nil)
    }

    @Test func aPendingJumpSurvivesARefusedPresentationAndConsumesOnce() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        try await seedHistory(store, count: 5)
        let state = TracklogAppState()
        let runtime = historyRuntime(store: store, state: state)
        let target = historyBase.addingTimeInterval(2 * 60)

        state.requestHistoryJump(target)
        await runtime.applyPendingHistoryJump()
        #expect(state.pendingHistoryJump == target, "a stopped runtime leaves the request pending")

        await runtime.start()
        await runtime.applyPendingHistoryJump()
        #expect(state.pendingHistoryJump == nil)
        #expect(state.historyJumpNotice != nil)
        #expect(state.listens.first?.startedAt == target)

        await runtime.applyPendingHistoryJump()
        #expect(state.listens.first?.startedAt == target, "a consumed jump is not replayed")

        await runtime.reloadHistory()
        #expect(state.historyJumpNotice == nil)
        #expect(state.listens.first?.startedAt == historyBase.addingTimeInterval(4 * 60))
    }
}
