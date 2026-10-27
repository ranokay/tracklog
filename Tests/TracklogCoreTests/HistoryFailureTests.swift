import Foundation
import Testing
@testable import TracklogCore

@Suite("History failures")
@MainActor
struct HistoryFailureTests: CaptureTestHelpers {
    @Test func aHistoryFailureSurvivesALaterWriteFailure() async throws {
        let clock = FakeClock(base)
        let source = ReplayedNowPlaying()
        let runtime = CaptureRuntime(
            clock: clock,
            source: source,
            store: FailingHistoryThenWriteStore(),
            allowlist: InMemoryAppAllowlist(),
            settings: CaptureSettings(scrobblingEnabled: true),
        )
        await runtime.start()

        await replay(thresholdSamples(track()), on: runtime, clock: clock)

        let failure = try #require(runtime.state.failure)
        #expect(failure.stage == .storage, "the latest failure is the write")
        #expect(runtime.state.historyFailure != nil, "history is still unavailable")
    }

    @Test func aSuccessfulHistoryReadClearsTheFailure() async {
        let clock = FakeClock(base)
        let source = ReplayedNowPlaying()
        let runtime = CaptureRuntime(
            clock: clock,
            source: source,
            store: RecoveringHistoryStore(),
            allowlist: InMemoryAppAllowlist(),
            settings: CaptureSettings(scrobblingEnabled: true),
        )
        await runtime.start()
        #expect(runtime.state.historyFailure != nil)

        await replay(thresholdSamples(track()), on: runtime, clock: clock)

        #expect(runtime.state.historyFailure == nil)
        #expect(runtime.state.failure == nil)
        #expect(runtime.state.listenCount == 1)
    }
}

private actor FailingHistoryThenWriteStore: ListenStore {
    func insert(_: Listen) async throws -> Listen? {
        throw DatabaseError.sqlite("disk full")
    }

    func page(limit _: Int, before _: ListenCursor?) async throws -> [Listen] {
        throw DatabaseError.sqlite("read failed")
    }

    func count() async throws -> Int {
        throw DatabaseError.sqlite("read failed")
    }
}

private actor RecoveringHistoryStore: ListenStore {
    private var reads = 0

    func insert(_ listen: Listen) async throws -> Listen? {
        listen.stored(withID: 1)
    }

    func page(limit _: Int, before _: ListenCursor?) async throws -> [Listen] {
        reads += 1
        guard reads > 1 else { throw DatabaseError.sqlite("read failed") }
        return []
    }

    func count() async throws -> Int {
        0
    }
}
