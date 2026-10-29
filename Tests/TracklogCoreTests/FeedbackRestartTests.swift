import Foundation
import Testing
@testable import TracklogCore

@Suite("Feedback restart")
@MainActor
struct FeedbackRestartTests: CaptureTestHelpers {
    private let base = Date(timeIntervalSince1970: 1_000_000)

    @Test func anOldActionReadCannotPublishAfterRestart() async throws {
        let database = try TemporaryDatabase()
        let sqlite = try SQLiteListenStore(url: database.url)
        let credentials = MemoryCredentialStore()
        let clock = FakeClock(base)
        let probe = HUDProbe()
        let store = SuspendingFeedbackStore(sqlite)
        let brainz = makeFeedbackAdapter(kind: .listenBrainz)
        _ = try await saveHUDConnection(
            sqlite,
            credentials: credentials,
            kind: .listenBrainz,
            base: base,
        )
        let runtime = makeFeedbackRuntime(
            store: store,
            clock: clock,
            probe: probe,
            adapters: [brainz],
            credentials: credentials,
        )
        await runtime.start()
        let listen = try await insertHistoryListen(sqlite, base: base)
        let identity = listen.processed.identity

        await store.holdNextFeedbackRead()
        let old = Task { await runtime.toggleLove(for: listen) }
        await store.waitUntilReading()

        runtime.stop()
        await runtime.start()

        let fresh = Task { await runtime.toggleLove(for: listen) }
        await fresh.value
        #expect(runtime.state.feedback(for: identity)?.score == .loved)
        #expect(await brainz.feedback.count == 1)

        await store.release()
        await old.value

        #expect(runtime.state.feedback(for: identity)?.score == .loved)
        #expect(await brainz.feedback.count == 1)
        #expect(probe.presentations.last?.spoken == "Loved on ListenBrainz.")
    }
}
