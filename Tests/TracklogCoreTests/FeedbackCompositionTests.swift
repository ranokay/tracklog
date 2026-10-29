import Foundation
import Testing
@testable import TracklogCore

@Suite("Feedback composition")
@MainActor
struct FeedbackCompositionTests: CaptureTestHelpers {
    @Test func loveFansOutToEveryEnabledSupportingConnectionAndSkipsTheRest() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let credentials = MemoryCredentialStore()
        let clock = FakeClock(base)
        let probe = HUDProbe()
        let brainz = makeFeedbackAdapter(
            kind: .listenBrainz,
            supportsHate: true,
            requiresReference: true,
            reference: .mbid("mbid-lookup"),
        )
        let lastFM = makeFeedbackAdapter(kind: .lastFM, supportsLove: false)
        let libre = makeFeedbackAdapter(kind: .libreFM)
        let brainzConnection = try await saveHUDConnection(
            store,
            credentials: credentials,
            kind: .listenBrainz,
            base: base,
        )
        let lastFMConnection = try await saveHUDConnection(
            store,
            credentials: credentials,
            kind: .lastFM,
            identity: "listener-lastfm",
            base: base,
        )
        let enabledLibre = try await saveHUDConnection(
            store,
            credentials: credentials,
            kind: .libreFM,
            endpoint: .libreFM,
            identity: "libre-one",
            base: base,
        )
        let disabledEndpoint = try #require(
            ServiceEndpoint(normalizing: "https://music.example.com"),
        )
        let disabledLibre = try await saveHUDConnection(
            store,
            credentials: credentials,
            kind: .libreFM,
            endpoint: disabledEndpoint,
            identity: "libre-two",
            base: base,
            isEnabled: false,
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
        try await runtime.setCurrentConnection(lastFMConnection.id)

        await runtime.toggleLove(for: listen)

        let brainzFeedback = await brainz.feedback
        let lastFMFeedback = await lastFM.feedback
        let libreFeedback = await libre.feedback
        let brainzLookups = await brainz.lookups
        #expect(brainzFeedback.map(\.action) == [.love])
        #expect(brainzFeedback.first?.connectionID == brainzConnection.id)
        #expect(brainzLookups.count == 1)
        #expect(brainzFeedback.first?.reference == .mbid("mbid-lookup"))
        #expect(lastFMFeedback.isEmpty, "an unsupported connection is never called")
        #expect(libreFeedback.map(\.connectionID) == [enabledLibre.id])
        #expect(libreFeedback.map(\.connectionID).contains(disabledLibre.id) == false)
        #expect(runtime.state.feedbackSupport == FeedbackSupport(canLove: true, canHate: true))

        let loved = try #require(probe.presentations.last)
        #expect(loved.id == "hud.confirm.love")
        #expect(loved.spoken == "Loved on 2 services.")
        #expect(runtime.state.feedback(for: listen.processed.identity)?.score == .loved)

        await runtime.toggleLove(for: listen)

        let afterUnlove = await brainz.feedback
        let afterUnloveLibre = await libre.feedback
        #expect(afterUnlove.map(\.action) == [.love, .unlove])
        #expect(afterUnloveLibre.map(\.action) == [.love, .unlove])
        #expect(runtime.state.feedback(for: listen.processed.identity) == nil)
        #expect(probe.presentations.last?.spoken == "Unloved on 2 services.")
    }

    @Test func hateGoesOnlyToSupportingListenBrainzConnections() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let credentials = MemoryCredentialStore()
        let clock = FakeClock(base)
        let probe = HUDProbe()
        let brainz = makeFeedbackAdapter(kind: .listenBrainz, supportsHate: true)
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

        await runtime.hate(listen)

        let brainzFeedback = await brainz.feedback
        #expect(brainzFeedback.map(\.action) == [.hate])
        #expect(await lastFM.feedback.isEmpty)
        #expect(await libre.feedback.isEmpty)
        #expect(runtime.state.feedback(for: listen.processed.identity)?.score == .hated)
        #expect(probe.presentations.last?.id == "hud.confirm.hate")
        #expect(probe.presentations.last?.spoken == "Hated on ListenBrainz.")
    }

    @Test func localFeedbackPersistsByProcessedIdentityAndReloads() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let credentials = MemoryCredentialStore()
        let clock = FakeClock(base)
        let probe = HUDProbe()
        let brainz = makeFeedbackAdapter(kind: .listenBrainz)
        _ = try await saveHUDConnection(
            store,
            credentials: credentials,
            kind: .listenBrainz,
            base: base,
        )
        let listen = try await insertHistoryListen(store, base: base)
        let first = makeHUDRuntime(
            store: store,
            clock: clock,
            probe: probe,
            adapters: [brainz],
            credentials: credentials,
        )
        await first.start()
        await first.toggleLove(for: listen)
        #expect(first.state.feedback(for: listen.processed.identity)?.score == .loved)
        first.stop()

        let secondProbe = HUDProbe()
        let second = makeHUDRuntime(
            store: store,
            clock: FakeClock(base),
            probe: secondProbe,
            adapters: [brainz],
            credentials: credentials,
        )
        await second.start()
        #expect(second.state.feedback(for: listen.processed.identity)?.score == .loved)

        let fromSpotify = Track(
            title: "Song",
            artist: "Artist",
            album: "",
            albumArtist: "",
            bundleID: "com.spotify.client",
        )
        await second.ingest(
            MediaSample(
                track: fromSpotify,
                elapsed: 0,
                playbackRate: 1,
                isPlaying: true,
                timestamp: base,
            ),
        )
        await eventually { second.state.nowPlayingFeedback?.score == .loved }
        #expect(second.state.nowPlayingFeedback?.score == .loved)
        #expect(second.state.nowPlaying?.track.bundleID == "com.spotify.client")
    }

    @Test func quickBlockIsExactArtistTitleAndLeavesHistory() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let credentials = MemoryCredentialStore()
        let clock = FakeClock(base)
        let probe = HUDProbe()
        let runtime = makeHUDRuntime(
            store: store,
            clock: clock,
            probe: probe,
            adapters: [],
            credentials: credentials,
        )
        let listen = try await insertHistoryListen(store, base: base)
        await runtime.start()
        let historyCount = runtime.state.historyCount

        let block = try await runtime.quickBlock(listen)

        #expect(block.track == "Song")
        #expect(block.artist == "Artist")
        #expect(block.album.isEmpty)
        #expect(block.albumArtist.isEmpty)
        #expect(runtime.state.blocks.count == 1)
        #expect(runtime.state.listens.contains { $0.id == listen.id })
        #expect(runtime.state.historyCount == historyCount)
        #expect(probe.presentations.last?.id == "hud.confirm.block")
        #expect(probe.presentations.last?.spoken == "Blocked Song. It will not scrobble again.")

        let future = track(title: "Song", artist: "Artist")
        await replay(thresholdSamples(future), on: runtime, clock: clock)

        #expect(runtime.state.historyCount == historyCount)
        #expect(runtime.state.listenCount == 0)
    }
}
