import Foundation
import Testing
@testable import TracklogCore

@Suite("Feedback reads")
@MainActor
struct FeedbackReadTests: CaptureTestHelpers {
    private let base = Date(timeIntervalSince1970: 1_000_000)

    @Test func aReadForOneTrackSurvivesAWriteToAnother() async throws {
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
        let other = try await insertHistoryListen(sqlite, title: "Other", base: base)
        let current = Track(
            title: "Current",
            artist: "Artist",
            album: "",
            albumArtist: "",
            bundleID: "com.apple.Music",
        )
        let currentIdentity = ListenMetadata(current).identity
        try await sqlite.setFeedback(.loved, for: currentIdentity, at: base)
        try await sqlite.setFeedback(.hated, for: other.processed.identity, at: base)
        let runtime = makeFeedbackRuntime(
            store: store,
            clock: clock,
            probe: probe,
            adapters: [brainz],
            credentials: credentials,
        )
        await runtime.start()
        #expect(runtime.state.feedback(for: other.processed.identity)?.score == .hated)

        await store.holdNextFeedbackRead()
        await runtime.ingest(
            MediaSample(
                track: current,
                elapsed: 0,
                playbackRate: 1,
                isPlaying: true,
                timestamp: base,
            ),
        )
        await store.waitUntilReading()
        await runtime.toggleLove(for: other)
        await store.release()
        await eventually { runtime.state.nowPlayingFeedback?.score == .loved }

        #expect(runtime.state.nowPlayingFeedback?.score == .loved)
        #expect(runtime.state.feedback(for: other.processed.identity)?.score == .loved)
        await runtime.ingest(
            MediaSample(
                track: current,
                elapsed: 2,
                playbackRate: 1,
                isPlaying: true,
                timestamp: base.addingTimeInterval(2),
            ),
        )
        #expect(runtime.state.nowPlayingFeedback?.score == .loved)
    }

    @Test func aMixedIdentityPageReadKeepsUntouchedIdentities() async throws {
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
        let first = try await insertHistoryListen(sqlite, title: "First", base: base)
        let second = try await insertHistoryListen(sqlite, title: "Second", base: base, start: 10)
        try await sqlite.setFeedback(.loved, for: first.processed.identity, at: base)
        try await sqlite.setFeedback(.hated, for: second.processed.identity, at: base)

        await store.holdNextFeedbackRead()
        let reload = Task { await runtime.reloadHistory() }
        await store.waitUntilReading()
        await runtime.toggleLove(for: second)
        await store.release()
        await reload.value

        #expect(runtime.state.feedback(for: first.processed.identity)?.score == .loved)
        #expect(runtime.state.feedback(for: second.processed.identity)?.score == .loved)
    }
}
