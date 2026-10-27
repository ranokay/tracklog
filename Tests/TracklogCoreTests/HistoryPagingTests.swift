import Foundation
import Testing
@testable import TracklogCore

@Suite("History paging ownership")
@MainActor
struct HistoryPagingTests: CaptureTestHelpers {
    @Test func aReloadDuringAPageLoadLetsTheNextPageStart() async {
        let store = SuspendedPageStore()
        let runtime = CaptureRuntime(
            clock: FakeClock(base),
            source: ReplayedNowPlaying(),
            store: store,
            scrobblingEnabled: true,
            historyPageSize: 2,
        )
        await runtime.start()
        #expect(runtime.state.listens.count == 2)

        await store.suspendNextPage()
        let staleLoad = Task { await runtime.loadMoreHistory() }
        while await store.pageIsSuspended == false {
            await Task.yield()
        }

        // A reload supersedes the in-flight page. The next page must be able
        // to start instead of waiting on the stale call's flag.
        await runtime.reloadVisibleHistory(in: store)
        await runtime.loadMoreHistory()

        #expect(runtime.state.listens.count == 4)
        #expect(Set(runtime.state.listens.compactMap(\.id)).count == 4)

        await store.releasePage()
        await staleLoad.value

        #expect(runtime.state.listens.count == 4)
        #expect(Set(runtime.state.listens.compactMap(\.id)).count == 4)
    }
}

private actor SuspendedPageStore: ListenStore {
    private let rows: [Listen]
    private var suspendNext = false
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var pageIsSuspended = false

    init() {
        rows = (0 ..< 5).reversed().map { index in
            let metadata = ListenMetadata(title: "Song \(index)", artist: "Artist")
            let start = Date(timeIntervalSince1970: 1_000_000 + Double(index))
            return Listen(
                id: Int64(index),
                raw: metadata,
                processed: metadata,
                bundleID: "com.apple.Music",
                duration: 200,
                playedDuration: 100,
                startedAt: start,
                capturedAt: start,
            )
        }
    }

    func suspendNextPage() {
        suspendNext = true
    }

    func page(limit: Int, before cursor: ListenCursor?) async throws -> [Listen] {
        if suspendNext {
            suspendNext = false
            pageIsSuspended = true
            await withCheckedContinuation { continuation = $0 }
            pageIsSuspended = false
        }

        let start = if let cursor {
            rows.firstIndex { $0.id == cursor.id }.map { $0 + 1 } ?? rows.count
        } else {
            0
        }
        return Array(rows.dropFirst(start).prefix(limit))
    }

    func count() async throws -> Int {
        rows.count
    }

    func insert(_ listen: Listen) async throws -> Listen? {
        listen
    }

    func releasePage() {
        continuation?.resume()
        continuation = nil
    }
}
