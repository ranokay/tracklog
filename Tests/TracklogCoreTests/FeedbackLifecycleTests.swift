import Foundation
import Testing
@testable import TracklogCore

@Suite("Feedback lifecycle")
@MainActor
struct FeedbackLifecycleTests: CaptureTestHelpers {
    private let base = Date(timeIntervalSince1970: 1_000_000)

    @Test func orderedLoveThenUnloveKeepsOrderAndClearsTheHeart() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let credentials = MemoryCredentialStore()
        let clock = FakeClock(base)
        let probe = HUDProbe()
        let gate = DeliveryGate()
        let brainz = makeFeedbackAdapter(kind: .listenBrainz, feedbackGate: gate)
        _ = try await saveHUDConnection(
            store,
            credentials: credentials,
            kind: .listenBrainz,
            base: base,
        )
        let listen = try await insertHistoryListen(store, base: base)
        let runtime = makeHUDRuntime(
            store: store,
            clock: clock,
            probe: probe,
            adapters: [brainz],
            credentials: credentials,
        )
        await runtime.start()

        let love = Task { await runtime.toggleLove(for: listen) }
        await gate.waitUntilEntered()
        let unlove = Task { await runtime.toggleLove(for: listen) }
        await turnMainActor()
        await gate.release()
        await love.value
        await unlove.value

        let feedback = await brainz.feedback
        #expect(feedback.map(\.action) == [.love, .unlove])
        #expect(runtime.state.feedback(for: listen.processed.identity) == nil)
        #expect(probe.announcements == ["Loved on ListenBrainz.", "Unloved on ListenBrainz."])
    }

    @Test func aCurrentTrackChangeDuringAReadKeepsTheNewTracksHeart() async throws {
        let database = try TemporaryDatabase()
        let sqlite = try SQLiteListenStore(url: database.url)
        let clock = FakeClock(base)
        let probe = HUDProbe()
        let store = SuspendingFeedbackStore(sqlite)
        let first = Track(title: "First", artist: "Artist", bundleID: "com.apple.Music")
        let second = Track(title: "Second", artist: "Artist", bundleID: "com.apple.Music")
        let firstIdentity = ListenMetadata(first).identity
        let secondIdentity = ListenMetadata(second).identity
        try await sqlite.setFeedback(.loved, for: firstIdentity, at: base)
        try await sqlite.setFeedback(.hated, for: secondIdentity, at: base)
        let runtime = makeFeedbackRuntime(store: store, clock: clock, probe: probe)
        await runtime.start()

        await store.holdNextFeedbackRead()
        let ingestFirst = Task {
            await runtime.ingest(
                MediaSample(
                    track: first,
                    elapsed: 0,
                    playbackRate: 1,
                    isPlaying: true,
                    timestamp: base,
                ),
            )
        }
        await store.waitUntilReading()
        await runtime.ingest(
            MediaSample(
                track: second,
                elapsed: 0,
                playbackRate: 1,
                isPlaying: true,
                timestamp: base.addingTimeInterval(2),
            ),
        )
        await store.release()
        await ingestFirst.value
        await eventually { runtime.state.nowPlayingFeedback?.score == .hated }

        #expect(runtime.state.nowPlaying?.track.title == "Second")
        #expect(runtime.state.nowPlayingFeedback?.score == .hated)
    }

    @Test func aStaleFeedbackReadCannotOverwriteANewerLocalWrite() async throws {
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
        try await sqlite.setFeedback(.hated, for: identity, at: base)

        await store.holdNextFeedbackRead()
        let reload = Task { await runtime.reloadHistory() }
        await store.waitUntilReading()
        await runtime.toggleLove(for: listen)
        #expect(runtime.state.feedback(for: identity)?.score == .loved)

        await store.release()
        await reload.value
        #expect(
            runtime.state.feedback(for: identity)?.score == .loved,
            "the stale read must not overwrite the local write",
        )
    }

    @Test func unlinkingWhileLookupIsSuspendedNeverShowsASuccess() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let credentials = MemoryCredentialStore()
        let clock = FakeClock(base)
        let probe = HUDProbe()
        let lookupGate = DeliveryGate()
        let brainz = makeFeedbackAdapter(
            kind: .listenBrainz,
            requiresReference: true,
            reference: .mbid("mbid-lookup"),
            lookupGate: lookupGate,
        )
        let connection = try await saveHUDConnection(
            store,
            credentials: credentials,
            kind: .listenBrainz,
            base: base,
        )
        let listen = try await insertHistoryListen(store, base: base)
        let runtime = makeHUDRuntime(
            store: store,
            clock: clock,
            probe: probe,
            adapters: [brainz],
            credentials: credentials,
        )
        await runtime.start()

        let love = Task { await runtime.toggleLove(for: listen) }
        await lookupGate.waitUntilEntered()
        _ = try await runtime.unlinkConnection(id: connection.id ?? -1)
        await lookupGate.release()
        await love.value

        #expect(await brainz.feedback.isEmpty)
        #expect(probe.presentations.isEmpty)
    }

    @Test func aToggleReadsTheStoredScoreBeforeTheInitialHeartReadCompletes() async throws {
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
        let current = Track(
            title: "Current",
            artist: "Artist",
            album: "",
            albumArtist: "",
            bundleID: "com.apple.Music",
        )
        let identity = ListenMetadata(current).identity
        try await sqlite.setFeedback(.loved, for: identity, at: base)
        let runtime = makeFeedbackRuntime(
            store: store,
            clock: clock,
            probe: probe,
            adapters: [brainz],
            credentials: credentials,
        )
        await runtime.start()

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
        #expect(runtime.state.nowPlayingFeedback == nil)

        await runtime.toggleLoveForCurrentTrack()

        let feedback = await brainz.feedback
        #expect(feedback.map(\.action) == [.unlove])
        #expect(runtime.state.nowPlayingFeedback == nil)

        await store.release()
        await turnMainActor()
        #expect(runtime.state.nowPlayingFeedback == nil)
    }

    @Test func stoppingAndRestartingCancelsQueuedFeedbackActions() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let credentials = MemoryCredentialStore()
        let clock = FakeClock(base)
        let probe = HUDProbe()
        let gate = DeliveryGate()
        let brainz = makeFeedbackAdapter(kind: .listenBrainz, feedbackGate: gate)
        _ = try await saveHUDConnection(
            store,
            credentials: credentials,
            kind: .listenBrainz,
            base: base,
        )
        let listen = try await insertHistoryListen(store, base: base)
        let runtime = makeHUDRuntime(
            store: store,
            clock: clock,
            probe: probe,
            adapters: [brainz],
            credentials: credentials,
        )
        await runtime.start()

        let first = Task { await runtime.toggleLove(for: listen) }
        await gate.waitUntilEntered()
        let second = Task { await runtime.toggleLove(for: listen) }
        let third = Task { await runtime.toggleLove(for: listen) }
        await turnMainActor()
        runtime.stop()
        await runtime.start()
        await gate.release()
        await first.value
        await second.value
        await third.value

        let feedback = await brainz.feedback
        #expect(feedback.count == 1)
        #expect(feedback.first?.action == .love)
        #expect(probe.presentations.isEmpty)
        #expect(runtime.state.feedback(for: listen.processed.identity)?.score == .loved)
    }
}
