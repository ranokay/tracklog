import Foundation
import Testing
@testable import TracklogCore

@Suite("Capture startup")
@MainActor
struct CaptureStartupTests: CaptureTestHelpers {
    @Test func cancellingAnInFlightStartAllowsRetry() async {
        let store = SuspendedReadStore()
        let clock = FakeClock(base)
        let source = ReplayedNowPlaying()
        let runtime = CaptureRuntime(
            clock: clock,
            source: source,
            store: store,
            allowlist: InMemoryAppAllowlist(),
            settings: CaptureSettings(scrobblingEnabled: true),
        )

        let first = Task { await runtime.start() }
        while await store.pendingReads < 1 {
            await Task.yield()
        }
        first.cancel()
        await store.releaseNextRead()
        await first.value

        #expect(source.startCount == 0)

        let second = Task { await runtime.start() }
        while await store.pendingReads < 1 {
            await Task.yield()
        }
        await store.releaseNextRead()
        await second.value

        #expect(source.startCount == 1)
        #expect(source.handler != nil)
    }

    @Test func cancellingStartStopsAFeedStartedWhileItWasReading() async {
        let store = SuspendedReadStore()
        let clock = FakeClock(base)
        let source = ReplayedNowPlaying()
        let runtime = CaptureRuntime(
            clock: clock,
            source: source,
            store: store,
            allowlist: InMemoryAppAllowlist(),
            settings: CaptureSettings(scrobblingEnabled: false),
        )

        let start = Task { await runtime.start() }
        while await store.pendingReads < 1 {
            await Task.yield()
        }

        runtime.setScrobblingEnabled(true)
        #expect(source.startCount == 1)

        start.cancel()
        await store.releaseNextRead()
        await start.value

        #expect(source.stopCount == 1)
        #expect(source.handler == nil)
        #expect(runtime.state.nowPlaying == nil)
        #expect(runtime.state.status == .idle)
    }

    @Test func aCancelledOlderStartDoesNotResetANewerStart() async {
        let store = SuspendedReadStore()
        let clock = FakeClock(base)
        let source = ReplayedNowPlaying()
        let runtime = CaptureRuntime(
            clock: clock,
            source: source,
            store: store,
            allowlist: InMemoryAppAllowlist(),
            settings: CaptureSettings(scrobblingEnabled: true),
        )

        let first = Task { await runtime.start() }
        while await store.pendingReads < 1 {
            await Task.yield()
        }

        runtime.stop()

        let second = Task { await runtime.start() }
        while await store.pendingReads < 2 {
            await Task.yield()
        }

        first.cancel()
        await store.releaseNextRead()
        await first.value

        #expect(source.startCount == 0, "the cancelled start must not arm the feed")

        await store.releaseNextRead()
        await second.value

        #expect(source.startCount == 1, "the newer start still owns the runtime")
        #expect(source.handler != nil)
    }
}

private actor SuspendedReadStore: ListenStore {
    private var continuations: [CheckedContinuation<Void, Never>] = []

    var pendingReads: Int {
        continuations.count
    }

    func insert(_ listen: Listen) async throws -> Listen? {
        listen.stored(withID: 1)
    }

    func page(limit _: Int, before _: ListenCursor?) async throws -> [Listen] {
        await withCheckedContinuation { continuations.append($0) }
        return []
    }

    func count() async throws -> Int {
        0
    }

    func releaseNextRead() {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume()
    }
}
