import Foundation
import Testing
@testable import TracklogCore

@Suite("Feedback HUD")
@MainActor
struct FeedbackHUDTests: CaptureTestHelpers {
    private let base = Date(timeIntervalSince1970: 1_000_000)

    @Test func hudCountsOnlyServicesThatSucceeded() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let credentials = MemoryCredentialStore()
        let clock = FakeClock(base)
        let probe = HUDProbe()
        let brainz = makeFeedbackAdapter(kind: .listenBrainz, feedbackAnswer: .rejected(nil))
        let lastFM = makeFeedbackAdapter(kind: .lastFM)
        let libre = makeFeedbackAdapter(kind: .libreFM)
        _ = try await saveHUDConnection(
            store,
            credentials: credentials,
            kind: .listenBrainz,
            base: base,
        )
        _ = try await saveHUDConnection(
            store,
            credentials: credentials,
            kind: .lastFM,
            identity: "listener-lastfm",
            base: base,
        )
        _ = try await saveHUDConnection(
            store,
            credentials: credentials,
            kind: .libreFM,
            identity: "libre",
            base: base,
        )
        let listen = try await insertHistoryListen(store, base: base)
        let runtime = makeHUDRuntime(
            store: store,
            clock: clock,
            probe: probe,
            adapters: [brainz, lastFM, libre],
            credentials: credentials,
        )
        await runtime.start()

        await runtime.toggleLove(for: listen)

        let loved = try #require(probe.presentations.last)
        #expect(loved.spoken == "Loved on 2 services.")
        #expect(runtime.state.feedback(for: listen.processed.identity)?.score == .loved)
    }

    @Test func allFailuresStaySilentAndKeepLocalKnowledge() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let credentials = MemoryCredentialStore()
        let clock = FakeClock(base)
        let probe = HUDProbe()
        let brainz = makeFeedbackAdapter(kind: .listenBrainz, feedbackAnswer: .rejected(nil))
        let lastFM = makeFeedbackAdapter(kind: .lastFM, feedbackAnswer: .rejected(nil))
        _ = try await saveHUDConnection(
            store,
            credentials: credentials,
            kind: .listenBrainz,
            base: base,
        )
        _ = try await saveHUDConnection(
            store,
            credentials: credentials,
            kind: .lastFM,
            identity: "listener-lastfm",
            base: base,
        )
        let listen = try await insertHistoryListen(store, base: base)
        let runtime = makeHUDRuntime(
            store: store,
            clock: clock,
            probe: probe,
            adapters: [brainz, lastFM],
            credentials: credentials,
        )
        await runtime.start()

        await runtime.toggleLove(for: listen)

        #expect(probe.presentations.isEmpty, "no failed service is reported as a success")
        #expect(runtime.state.feedback(for: listen.processed.identity)?.score == .loved)
    }

    @Test func noEligibleSupportingConnectionMeansNoAction() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let credentials = MemoryCredentialStore()
        let clock = FakeClock(base)
        let probe = HUDProbe()
        let brainz = makeFeedbackAdapter(kind: .listenBrainz, supportsHate: true)
        let lastFM = makeFeedbackAdapter(kind: .lastFM, supportsLove: false)
        _ = try await saveHUDConnection(
            store,
            credentials: credentials,
            kind: .listenBrainz,
            base: base,
            isEnabled: false,
        )
        _ = try await saveHUDConnection(
            store,
            credentials: credentials,
            kind: .lastFM,
            identity: "listener-lastfm",
            base: base,
            authState: .needsSignIn,
        )
        let listen = try await insertHistoryListen(store, base: base)
        let runtime = makeHUDRuntime(
            store: store,
            clock: clock,
            probe: probe,
            adapters: [brainz, lastFM],
            credentials: credentials,
        )
        await runtime.start()

        #expect(runtime.state.feedbackSupport == FeedbackSupport())
        await runtime.toggleLove(for: listen)
        await runtime.hate(listen)

        #expect(await brainz.feedback.isEmpty)
        #expect(await lastFM.feedback.isEmpty)
        #expect(runtime.state.feedback(for: listen.processed.identity) == nil)
        #expect(probe.presentations.isEmpty)
    }
}
