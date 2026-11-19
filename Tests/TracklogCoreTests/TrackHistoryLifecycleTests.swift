import Foundation
import Testing
@testable import TracklogCore

// MARK: - Track history

@Suite("Track history lifecycle")
@MainActor
struct TrackHistoryLifecycleTests: CaptureTestHelpers {
    @Test func aTrackReadFailureStaysInTheTrackViewAndCaptureContinues() async throws {
        let database = try TemporaryDatabase()
        let baseStore = try SQLiteListenStore(url: database.url)
        _ = try await baseStore.insert(
            historyListen(title: "Blue Monday", artist: "New Order", start: historyBase),
        )
        let store = FailingTrackHistoryStore(baseStore, failures: 1)
        let clock = FakeClock(historyBase.addingTimeInterval(600))
        let state = TracklogAppState()
        let runtime = historyRuntime(
            store: store,
            state: state,
            clock: clock,
            scrobbling: true,
        )
        await runtime.start()
        let feeds = state.listens
        let row = try #require(state.listens.first)
        await openTrackDetail(runtime, row)

        #expect(state.entityDetail?.track?.failure != nil)
        #expect(state.failure == nil, "a track read is not a global failure")
        #expect(state.historyFailure == nil)
        #expect(state.listens == feeds)

        await replayThreshold(
            track(title: "Blue Monday", artist: "New Order", album: ""),
            at: clock.now,
            on: runtime,
            clock: clock,
        )
        await eventually { state.listenCount == 1 }
        #expect(state.listenCount == 1, "capture still persists while the track view failed")

        await runtime.reloadEntityDetail()
        let track = try #require(state.entityDetail?.track)
        #expect(track.failure == nil)
        #expect(track.totalCount == 2)
        #expect(track.listens.count == 2)
    }

    @Test func aCaptureWhileTrackHistoryIsOpenAppearsOnReload() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        for index in 0 ..< 3 {
            _ = try await store.insert(
                historyListen(
                    title: "Blue Monday",
                    artist: "New Order",
                    start: historyBase.addingTimeInterval(Double(index - 10) * 60),
                ),
            )
        }
        let clock = FakeClock(historyBase)
        let state = TracklogAppState()
        let runtime = historyRuntime(
            store: store,
            state: state,
            clock: clock,
            scrobbling: true,
        )
        await runtime.start()
        let row = try #require(state.listens.first)
        await openTrackDetail(runtime, row)
        #expect(state.entityDetail?.track?.totalCount == 3)

        await replayThreshold(
            track(title: "Blue Monday", artist: "New Order", album: ""),
            at: clock.now,
            on: runtime,
            clock: clock,
        )
        await eventually { state.listenCount == 1 }
        #expect(state.entityDetail?.track?.totalCount == 3, "the open view is a snapshot")

        await runtime.reloadEntityDetail()
        let track = try #require(state.entityDetail?.track)
        #expect(track.totalCount == 4)
        #expect(track.listens.count == 4)
        #expect(track.listens.first?.startedAt == historyBase)
        #expect(Set(track.listens.compactMap(\.id)).count == 4, "the reload has no duplicate row")
        #expect(track.firstListenedAt == historyBase.addingTimeInterval(-10 * 60))
    }

    @Test func trackHistorySurvivesRelaunchAndRestartClearsNavigation() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        for index in 0 ..< 5 {
            _ = try await store.insert(
                historyListen(
                    title: "Blue Monday",
                    artist: "New Order",
                    start: historyBase.addingTimeInterval(Double(index) * 60),
                ),
            )
        }
        let state = TracklogAppState()
        let first = historyRuntime(store: store, state: state, pageSize: 2)
        await first.start()
        await first.jumpHistory(to: historyBase.addingTimeInterval(60))
        let row = try #require(state.listens.first { $0.processed.title == "Blue Monday" })
        await openTrackDetail(first, row)
        state.requestHistoryJump(historyBase.addingTimeInterval(120))
        let firstTrack = try #require(state.entityDetail?.track)
        #expect(firstTrack.totalCount == 5)
        #expect(firstTrack.firstListenedAt == historyBase)
        first.stop()
        #expect(state.entityDetail?.track == nil)
        #expect(state.historyJumpNotice == nil)
        #expect(state.pendingHistoryJump == nil)

        await store.close()
        let reopened = try SQLiteListenStore(url: database.url)
        let secondState = TracklogAppState()
        let second = historyRuntime(store: reopened, state: secondState, pageSize: 2)
        await second.start()
        let secondRow = try #require(secondState.listens.first)
        await openTrackDetail(second, secondRow)
        let secondTrack = try #require(secondState.entityDetail?.track)

        #expect(secondTrack.totalCount == firstTrack.totalCount)
        #expect(secondTrack.firstListenedAt == firstTrack.firstListenedAt)
        #expect(secondTrack.listens.map(\.id) == firstTrack.listens.map(\.id))
        #expect(secondState.listens.first?.startedAt == historyBase.addingTimeInterval(4 * 60))
    }

    @Test func aCancelledLoadMoreLeavesTheViewReadyToRetry() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        for index in 0 ..< 250 {
            _ = try await store.insert(
                historyListen(
                    title: "Blue Monday",
                    artist: "New Order",
                    start: historyBase.addingTimeInterval(Double(index) * 60),
                ),
            )
        }
        let state = TracklogAppState()
        let runtime = historyRuntime(store: store, state: state, pageSize: 100)
        await runtime.start()
        let row = try #require(state.listens.first)
        await openTrackDetail(runtime, row)
        #expect(state.entityDetail?.track?.listens.count == 100)
        #expect(state.entityDetail?.track?.hasMore == true)

        let gate = ChartHoldGate()
        let counter = ChartHoldCounter()
        await gate.startHolding()
        await store.chartReader.setRowObserver { rowIndex in
            if rowIndex == 64, await counter.takeFirst() {
                await gate.enter()
            }
        }

        let cancelled = Task { await runtime.loadMoreEntityListens() }
        #expect(await gate.waitUntilEntered(1), "the load-more scan is held")
        cancelled.cancel()
        await gate.release()
        await cancelled.value

        #expect(state.entityDetail?.track?.isLoading == false,
                "a cancelled page releases the loading flag")
        #expect(state.entityDetail?.track?.listens.count == 100)
        #expect(state.entityDetail?.track?.hasMore == true)
        await store.chartReader.setRowObserver(nil)

        await runtime.loadMoreEntityListens()
        let track = try #require(state.entityDetail?.track)
        #expect(track.listens.count == 200)
        #expect(track.listens[100].id == 150,
                "the retry starts at the same cursor, with no skipped row")
        #expect(Set(track.listens.compactMap(\.id)).count == 200)
        #expect(track.hasMore)

        await runtime.loadMoreEntityListens()
        #expect(state.entityDetail?.track?.listens.count == 250)
        #expect(state.entityDetail?.track?.hasMore == false)
        #expect(Set(state.entityDetail?.track?.listens.compactMap(\.id) ?? []).count == 250)
    }

    @Test func aHeldTrackHistoryScanDoesNotBlockCapture() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        for index in 0 ..< 200 {
            _ = try await store.insert(
                historyListen(title: "Archive \(index)", start: historyBase.addingTimeInterval(Double(index) * 60)),
            )
        }
        _ = try await store.insert(
            historyListen(title: "Blue Monday", artist: "New Order", start: historyBase.addingTimeInterval(20_000)),
        )
        let clock = FakeClock(historyBase.addingTimeInterval(30_000))
        let state = TracklogAppState()
        let runtime = historyRuntime(store: store, state: state, clock: clock, scrobbling: true)
        await runtime.start()
        let row = try #require(state.listens.first { $0.processed.title == "Blue Monday" })

        let gate = ChartHoldGate()
        let counter = ChartHoldCounter()
        await gate.startHolding()
        await store.chartReader.setRowObserver { rowIndex in
            if rowIndex == 64, await counter.takeFirst() {
                await gate.enter()
            }
        }

        let open = Task { await openTrackDetail(runtime, row) }
        #expect(await gate.waitUntilEntered(1), "the track summary scan is held")
        await replayThreshold(
            track(title: "Blue Monday", artist: "New Order", album: ""),
            at: clock.now,
            on: runtime,
            clock: clock,
        )
        await eventually { state.listenCount == 1 }
        #expect(state.listenCount == 1, "capture persists while the read connection is held")
        #expect(state.nowPlaying?.track.title == "Blue Monday")

        await gate.release()
        await open.value
        await runtime.reloadEntityDetail()
        #expect(state.entityDetail?.track?.totalCount == 2)
        await store.chartReader.setRowObserver(nil)
    }
}
