import Foundation
import Testing
@testable import TracklogCore

private struct TrackVariant {
    let raw: String
    let album: String
    let player: String
}

// MARK: - Track history

@Suite("Track history")
@MainActor
struct TrackHistoryTests: CaptureTestHelpers {
    @Test func trackHistoryShowsFullCountFirstListenAndPagesIndependently() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let base = historyBase
        for index in 0 ..< 200 {
            let isTrack = !index.isMultiple(of: 4)
            _ = try await store.insert(
                historyListen(
                    title: isTrack ? "Blue Monday" : "Dreams",
                    artist: isTrack ? "New Order" : "Fleetwood Mac",
                    album: isTrack ? "Power, Corruption & Lies" : "Rumours",
                    start: base.addingTimeInterval(Double(index) * 60),
                ),
            )
        }
        let state = TracklogAppState()
        let runtime = historyRuntime(store: store, state: state)
        await runtime.start()
        let loadedFeed = state.listens
        let row = try #require(state.listens.first { $0.processed.title == "Blue Monday" })

        await openTrackDetail(runtime, row)

        var track = try #require(state.entityDetail?.track)
        #expect(track.totalCount == 150)
        #expect(track.listens.count == 50)
        #expect(track.hasMore)
        #expect(track.firstListenedAt == base.addingTimeInterval(60),
                "the earliest track listen is the first date")
        #expect(state.listens == loadedFeed, "the feed is not replaced")

        var loads = 0
        while state.entityDetail?.track?.hasMore == true, loads < 10 {
            await runtime.loadMoreEntityListens()
            loads += 1
        }
        track = try #require(state.entityDetail?.track)
        #expect(loads == 2)
        #expect(track.listens.count == 150)
        #expect(Set(track.listens.compactMap(\.id)).count == 150)
        #expect(track.listens.last?.startedAt == base.addingTimeInterval(60))
        #expect(!track.hasMore)
    }

    @Test func trackHistoryUsesTheSharedTracksChartKey() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let edits = [
            simpleEditRule(match: .init(track: "cafe"), replace: .init(track: "Café")),
        ]
        let variants = [
            TrackVariant(raw: "Cafe", album: "Album A", player: "com.apple.Music"),
            TrackVariant(raw: "CAFE", album: "Album B", player: "com.spotify.client"),
            TrackVariant(raw: "Café", album: "Album A", player: "com.spotify.client"),
            TrackVariant(raw: "CAFÉ", album: "Album B", player: "com.apple.Music"),
        ]
        for (index, variant) in variants.enumerated() {
            let raw = Track(
                title: variant.raw,
                artist: "Artist",
                album: variant.album,
                bundleID: variant.player,
            )
            let processed = try #require(MetadataPipeline.process(raw, edits: edits))
            _ = try await store.insert(
                Listen(
                    raw: ListenMetadata(raw),
                    processed: processed,
                    bundleID: variant.player,
                    duration: 200,
                    playedDuration: 200,
                    startedAt: historyBase.addingTimeInterval(Double(index) * 60),
                    capturedAt: historyBase.addingTimeInterval(Double(index) * 60 + 200),
                ),
            )
        }
        _ = try await store.insert(
            historyListen(title: "Other", artist: "Someone Else", start: historyBase.addingTimeInterval(600)),
        )
        let expectedKey = try #require(LocalTrackIdentity.key(title: "Café", artist: "Artist"))

        let chart = try await store.localChart(
            type: .tracks,
            window: LocalChartWindow(
                period: .allTime,
                range: nil,
                timeZoneID: Calendar.current.timeZone.identifier,
            ),
            limit: 50,
        )
        let chartItem = try #require(chart.items.first { $0.identityKey == expectedKey })
        #expect(chartItem.count == 4)

        let state = TracklogAppState()
        let runtime = historyRuntime(store: store, state: state)
        await runtime.start()
        let row = try #require(state.listens.first { $0.processed.title == "Café" })
        await openTrackDetail(runtime, row)

        let track = try #require(state.entityDetail?.track)
        #expect(track.identityKey == expectedKey)
        #expect(track.totalCount == chartItem.count, "track history and the Tracks chart agree")
        #expect(track.totalCount == 4)
        #expect(track.firstListenedAt == historyBase)
    }

    @Test func aBlankArtistHasItsOwnTitleOnlyHistory() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        _ = try await store.insert(historyListen(title: "Orphan", artist: "", start: historyBase))
        _ = try await store.insert(historyListen(title: "Orphan", artist: "Artist", start: historyBase + 60))
        let state = TracklogAppState()
        let runtime = historyRuntime(store: store, state: state)
        await runtime.start()
        let blank = try #require(state.listens.first { $0.processed.artist.isEmpty })
        await openTrackDetail(runtime, blank)

        let track = try #require(state.entityDetail?.track)
        #expect(track.totalCount == 1)
        #expect(track.identityKey == LocalTrackIdentity.key(title: "Orphan", artist: ""))
        #expect(track.identityKey != LocalTrackIdentity.chartKey(title: "Orphan", artist: "Artist"))

        let chart = try await store.localChart(
            type: .tracks,
            window: LocalChartWindow(
                period: .allTime,
                range: nil,
                timeZoneID: Calendar.current.timeZone.identifier,
            ),
            limit: 50,
        )
        #expect(!chart.items.contains { $0.identityKey == track.identityKey })
        #expect(chart.items.contains { $0.identityKey == LocalTrackIdentity.chartKey(title: "Orphan", artist: "Artist") })
    }

    @Test func trackHistoryIgnoresDeliveryTargetsAndTheCurrentConnection() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let transport = ScriptedTransport([listenBrainzValidResponse(user: "history-user")])
        let state = TracklogAppState()
        let runtime = CaptureRuntime(
            state: state,
            clock: FakeClock(historyBase),
            source: ReplayedNowPlaying(),
            store: store,
            allowlist: InMemoryAppAllowlist(),
            credentials: MemoryCredentialStore(),
            serviceAdapters: [ListenBrainzAdapter(transport: transport)],
            settings: CaptureSettings(scrobblingEnabled: false),
            historyPageSize: 50,
        )
        await runtime.start()
        let connection = try await runtime.link(kind: .listenBrainz, credential: "token")
        let connectionID = try #require(connection.id)
        for index in 0 ..< 20 {
            _ = try await store.insert(
                historyListen(
                    title: "Blue Monday",
                    artist: "New Order",
                    start: historyBase.addingTimeInterval(Double(index) * 60),
                ),
                targets: [connectionID],
            )
        }
        for index in 0 ..< 10 {
            _ = try await store.insert(
                historyListen(
                    title: "Dreams",
                    artist: "Fleetwood Mac",
                    start: historyBase.addingTimeInterval(600 + Double(index) * 60),
                ),
            )
        }
        await runtime.reloadHistory()
        let row = try #require(state.listens.first { $0.processed.title == "Blue Monday" })
        await openTrackDetail(runtime, row)

        var track = try #require(state.entityDetail?.track)
        #expect(track.totalCount == 20, "one listen with a target is still one listen")
        #expect(track.listens.count == 20)
        #expect(state.currentConnectionID == connectionID)
        let requestsAfterTrackRead = await transport.requests.count
        #expect(requestsAfterTrackRead == 1, "track history makes no service read")

        try await runtime.setCurrentConnection(nil)
        await runtime.reloadEntityDetail()
        track = try #require(state.entityDetail?.track)
        #expect(track.totalCount == 20)
        #expect(track.listens.count == 20)
    }
}
