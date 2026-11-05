// swiftlint:disable file_length
import Foundation
import Testing
@testable import TracklogCore

@Suite("Chart local read model")
@MainActor
// swiftlint:disable:next type_body_length
struct ChartLocalTests: CaptureTestHelpers {
    private let utc = TimeZone(identifier: "UTC")!

    // swiftlint:disable:next function_body_length
    @Test func localChartsCountEachListenOnceAcrossDeliveriesAndHistoryPages() async throws {
        let database = try TemporaryDatabase()
        let now = chartDate(2026, 10, 31, 12)
        let clock = FakeClock(now)
        let store = try SQLiteListenStore(url: database.url)
        let lastFM = try await store.save(Connection(
            kind: .lastFM,
            endpoint: .lastFM,
            identity: "listener",
            createdAt: now,
        ))
        let listenBrainz = try await store.save(Connection(
            kind: .listenBrainz,
            endpoint: .listenBrainz,
            identity: "listener",
            createdAt: now,
        ))
        let libreFM = try await store.save(Connection(
            kind: .libreFM,
            endpoint: .libreFM,
            identity: "listener",
            createdAt: now,
        ))
        let targets = [lastFM.id, listenBrainz.id, libreFM.id].compactMap(\.self)

        var threeTargetListen: Listen?
        for index in 0 ..< 5 {
            let listen = chartListen(
                title: "Track \(index)",
                artist: "Three Targets Band",
                startedAt: now.addingTimeInterval(Double(index)),
            )
            let stored = try await store.insert(listen, targets: index == 0 ? targets : [])
            if index == 0 {
                threeTargetListen = stored
            }
        }
        let deliveries = try await store.deliveries(for: threeTargetListen?.id ?? -1)
        #expect(deliveries.count == 3)
        try await store.markDelivered(deliveries[0].id, at: now, reference: nil)
        try await store.markFailed(
            deliveries[1].id,
            attempts: 1,
            at: now,
            nextAttemptAt: now.addingTimeInterval(60),
            error: "retry",
        )
        try await store.abandon(deliveries[2].id, attempts: 1, lastAttemptAt: now, reason: "abandoned")

        for index in 0 ..< 114 {
            try await store.insert(
                chartListen(
                    title: "Other \(index)",
                    artist: "Artist \(index % 57)",
                    startedAt: now.addingTimeInterval(10 + Double(index)),
                ),
            )
        }
        try await store.insert(
            chartListen(
                title: "Untargeted",
                artist: "Zero Target",
                startedAt: now.addingTimeInterval(200),
            ),
        )

        let state = TracklogAppState()
        let calendarBox = ChartCalendarBox(chartCalendar(utc))
        let runtime = makeChartRuntime(
            database: database,
            clock: clock,
            transport: ChartHTTPTransport { _ in
                HTTPResponse(statusCode: 500, body: Data())
            },
            state: state,
            selection: chartSelection(source: .local, period: .allTime, now: now, calendar: calendarBox.calendar),
            calendarBox: calendarBox,
            historyPageSize: 10,
        )
        await runtime.start()

        #expect(state.historyCount == 120)
        #expect(state.listens.count == 10)
        #expect(state.historyHasMore)

        await runtime.charts?.show()

        let snapshot = try #require(state.chartState.snapshot)
        #expect(snapshot.localTotal == 120, "deliveries never multiply a local listen")
        #expect(snapshot.items.count == 50, "the list is bounded")
        #expect(snapshot.omittedCount == 0)
        #expect(snapshot.items.first?.title == "Three Targets Band")
        #expect(snapshot.items.first?.count == 5, "three targets plus four zero-target listens count five")
        #expect(state.chartState.totals == .local(120))
        #expect(state.historyCount == 120, "chart loading leaves History's total intact")
    }

    @Test func groupingNormalizesAndOmitMissingMetadataWithoutChangingFeedbackKeys() async throws {
        let database = try TemporaryDatabase()
        let now = chartDate(2026, 10, 31, 12)
        let clock = FakeClock(now)
        let store = try SQLiteListenStore(url: database.url)
        // swiftlint:disable:next large_tuple
        let rows: [(String, String, String, String, String, TimeInterval)] = [
            ("Song", "  ARTIST  ", "Album", "", "com.apple.Music", 0),
            ("song", "artist", " album ", "ALBUM ARTIST", "com.apple.Music", 1),
            ("Song", "Artist", "Other", "Album Artist", "com.spotify.client", 2),
            ("Song", "Artist", "", "", "com.apple.Music", 3),
            ("   ", "Artist", "", "", "com.apple.Music", 4),
            ("Song", "", "", "", "com.apple.Music", 5),
        ]
        for row in rows {
            try await store.insert(chartListen(
                title: row.0,
                artist: row.1,
                album: row.2,
                albumArtist: row.3,
                bundleID: row.4,
                startedAt: now.addingTimeInterval(row.5),
            ))
        }
        let feedbackIdentity = ListenMetadata(
            title: "Song",
            artist: "Artist",
            album: "Other",
            albumArtist: "Album Artist",
        ).identity
        try await store.setFeedback(.loved, for: feedbackIdentity, at: now)

        let state = TracklogAppState()
        let calendarBox = ChartCalendarBox(chartCalendar(utc))
        var selection = chartSelection(source: .local, period: .allTime, now: now, calendar: calendarBox.calendar)
        selection.period = .allTime
        let runtime = makeChartRuntime(
            database: database,
            clock: clock,
            transport: ChartHTTPTransport { _ in HTTPResponse(statusCode: 500, body: Data()) },
            state: state,
            selection: selection,
            calendarBox: calendarBox,
        )
        await runtime.start()
        await runtime.charts?.show()

        let artists = try #require(state.chartState.snapshot)
        #expect(artists.localTotal == 6)
        #expect(artists.items.count == 1)
        #expect(artists.items.first?.title == "Artist", "the most frequent spelling wins")
        #expect(artists.items.first?.count == 5)
        #expect(artists.omittedCount == 1)

        await runtime.charts?.selectType(.albums)
        let albums = try #require(state.chartState.snapshot)
        #expect(albums.localTotal == 6)
        #expect(albums.items.count == 3)
        #expect(albums.omittedCount == 3)
        #expect(albums.items.contains { $0.title == "Album" && $0.subtitle == "ARTIST" })
        #expect(albums.items.contains { $0.title == "album" && $0.subtitle == "ALBUM ARTIST" })
        #expect(albums.items.contains { $0.title == "Other" && $0.subtitle == "Album Artist" })

        await runtime.charts?.selectType(.tracks)
        let tracks = try #require(state.chartState.snapshot)
        #expect(tracks.items.count == 1)
        #expect(tracks.items.first?.title == "Song")
        #expect(tracks.items.first?.count == 4, "the same title and artist merges across albums and players")
        #expect(tracks.omittedCount == 2)
        #expect(state.feedback(for: feedbackIdentity)?.score == .loved)

        let stored = try await store.page(limit: 10, before: nil)
        #expect(stored.contains { $0.processed.album == "Other" && $0.processed.albumArtist == "Album Artist" })
    }

    @Test func albumGroupingRequiresAlbumAndAnArtistFallback() async throws {
        let database = try TemporaryDatabase()
        let now = chartDate(2026, 10, 31, 12)
        let clock = FakeClock(now)
        let store = try SQLiteListenStore(url: database.url)
        // swiftlint:disable:next large_tuple
        let rows: [(String, String, String, String)] = [
            ("A", "", "Unknown", ""),
            ("B", "   ", "Unknown", "  "),
            ("C", "", "Known", "Album Artist"),
            ("D", "Track Artist", "Fallback", "   "),
        ]
        for (index, row) in rows.enumerated() {
            try await store.insert(chartListen(
                title: row.0,
                artist: row.1,
                album: row.2,
                albumArtist: row.3,
                startedAt: now.addingTimeInterval(Double(index)),
            ))
        }
        let state = TracklogAppState()
        let calendarBox = ChartCalendarBox(chartCalendar(utc))
        var selection = chartSelection(source: .local, period: .allTime, now: now, calendar: calendarBox.calendar)
        selection.type = .albums
        let runtime = makeChartRuntime(
            database: database,
            clock: clock,
            transport: ChartHTTPTransport { _ in HTTPResponse(statusCode: 500, body: Data()) },
            state: state,
            selection: selection,
            calendarBox: calendarBox,
        )
        await runtime.start()
        await runtime.charts?.show()

        let snapshot = try #require(state.chartState.snapshot)
        #expect(snapshot.localTotal == 4)
        #expect(snapshot.omittedCount == 2, "an album with no album artist or track artist is omitted")
        #expect(snapshot.items.count == 2)
        #expect(snapshot.items.contains { $0.title == "Known" && $0.subtitle == "Album Artist" })
        #expect(snapshot.items.contains { $0.title == "Fallback" && $0.subtitle == "Track Artist" })
    }

    @Test func localArtworkChoiceIsDeterministic() async throws {
        let database = try TemporaryDatabase()
        let now = chartDate(2026, 10, 31, 12)
        let clock = FakeClock(now)
        let store = try SQLiteListenStore(url: database.url)
        try await store.insert(chartListen(
            title: "Older",
            artist: "Art",
            startedAt: now,
            artworkHash: "old-cover",
        ))
        try await store.insert(chartListen(
            title: "Newer",
            artist: "Art",
            startedAt: now.addingTimeInterval(10),
            artworkHash: "new-cover",
        ))
        let state = TracklogAppState()
        let calendarBox = ChartCalendarBox(chartCalendar(utc))
        let runtime = makeChartRuntime(
            database: database,
            clock: clock,
            transport: ChartHTTPTransport { _ in HTTPResponse(statusCode: 500, body: Data()) },
            state: state,
            selection: chartSelection(source: .local, period: .allTime, now: now, calendar: calendarBox.calendar),
            calendarBox: calendarBox,
        )
        await runtime.start()
        await runtime.charts?.show()
        #expect(state.chartState.snapshot?.items.first?.artworkHash == "old-cover")
    }

    @Test func localWindowMembershipIsHalfOpen() async throws {
        let database = try TemporaryDatabase()
        let now = chartDate(2026, 10, 31, 12)
        let clock = FakeClock(now)
        let store = try SQLiteListenStore(url: database.url)
        let atStart = chartDate(2026, 10, 31)
        let beforeEnd = chartDate(2026, 10, 31, 23, 59)
        let atEnd = chartDate(2026, 11, 1)
        let previous = chartDate(2026, 10, 30, 23, 59)
        for (index, date) in [atStart, beforeEnd, atEnd, previous].enumerated() {
            try await store.insert(chartListen(
                title: "Track \(index)",
                artist: "Artist \(index)",
                startedAt: date,
            ))
        }
        let state = TracklogAppState()
        let calendarBox = ChartCalendarBox(chartCalendar(utc))
        let runtime = makeChartRuntime(
            database: database,
            clock: clock,
            transport: ChartHTTPTransport { _ in HTTPResponse(statusCode: 500, body: Data()) },
            state: state,
            selection: chartSelection(source: .local, period: .today, now: now, calendar: calendarBox.calendar),
            calendarBox: calendarBox,
        )
        await runtime.start()
        await runtime.charts?.show()
        #expect(state.chartState.snapshot?.localTotal == 2)
        #expect(state.chartState.snapshot?.items.map(\.title) == ["Artist 0", "Artist 1"])
        #expect(ChartCopy.periodLabel(state.chartState, calendar: chartCalendar(utc)) == "Today")
        #expect(ChartCopy.listTitle(type: .artists, period: "Today") == "Top 50 artists · Today")
        #expect(ChartCopy.rowAccessibilityValue(source: "On this Mac", period: "Today") == "On this Mac, Today")
    }

    @Test func aTimeZoneChangeRecomputesTheLocalWindowWhileOpen() async throws {
        let database = try TemporaryDatabase()
        let losAngeles = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let now = chartDate(2026, 3, 8, 12, timeZone: losAngeles)
        let clock = FakeClock(now)
        let store = try SQLiteListenStore(url: database.url)
        try await store.insert(chartListen(
            title: "UTC only",
            artist: "UTC Artist",
            startedAt: chartDate(2026, 3, 9, 3),
        ))
        try await store.insert(chartListen(
            title: "Los Angeles only",
            artist: "Los Angeles Artist",
            startedAt: chartDate(2026, 3, 8, 1),
        ))

        let state = TracklogAppState()
        let calendarBox = ChartCalendarBox(chartCalendar(losAngeles))
        let runtime = makeChartRuntime(
            database: database,
            clock: clock,
            transport: ChartHTTPTransport { _ in HTTPResponse(statusCode: 500, body: Data()) },
            state: state,
            selection: chartSelection(
                source: .local,
                period: .today,
                now: now,
                calendar: calendarBox.calendar,
            ),
            calendarBox: calendarBox,
        )
        await runtime.start()
        await runtime.charts?.show()
        #expect(state.chartState.snapshot?.items.map(\.title) == ["UTC Artist"])

        calendarBox.calendar = chartCalendar(utc)
        await runtime.charts?.environmentChanged()
        #expect(state.chartState.snapshot?.items.map(\.title) == ["Los Angeles Artist"])
    }

    @Test func localStandardCacheStaysBoundedAcrossWindowAndTimeZoneChanges() async throws {
        let database = try TemporaryDatabase()
        let now = chartDate(2026, 10, 31, 12)
        let clock = FakeClock(now)
        let store = try SQLiteListenStore(url: database.url)
        try await store.insert(chartListen(title: "Song", artist: "Artist", startedAt: now))
        let state = TracklogAppState()
        let calendarBox = ChartCalendarBox(chartCalendar(utc))
        let runtime = makeChartRuntime(
            database: database,
            clock: clock,
            transport: ChartHTTPTransport { _ in HTTPResponse(statusCode: 500, body: Data()) },
            state: state,
            selection: chartSelection(source: .local, period: .today, now: now, calendar: calendarBox.calendar),
            calendarBox: calendarBox,
        )
        await runtime.start()
        await runtime.charts?.show()
        #expect(try await store.chartCacheCount() == 1)

        clock.advance(to: now.addingTimeInterval(86_400))
        await runtime.charts?.refresh()
        #expect(try await store.chartCacheCount() == 1, "a new rolling window replaces the old local snapshot")

        calendarBox.calendar = try chartCalendar(#require(TimeZone(identifier: "America/Los_Angeles")))
        await runtime.charts?.environmentChanged()
        #expect(try await store.chartCacheCount() == 1, "a time-zone change replaces the old local snapshot")
    }

    @Test func savingACustomRangeIncludesTheEndDayAndPersistsLocalSource() async throws {
        let database = try TemporaryDatabase()
        let now = chartDate(2026, 10, 31, 12)
        let clock = FakeClock(now)
        let store = try SQLiteListenStore(url: database.url)
        for (index, date) in [
            chartDate(2026, 10, 1),
            chartDate(2026, 10, 14, 23, 59),
            chartDate(2026, 10, 15),
        ].enumerated() {
            try await store.insert(chartListen(
                title: "Track \(index)",
                artist: "Artist \(index)",
                startedAt: date,
            ))
        }
        let state = TracklogAppState()
        let calendarBox = ChartCalendarBox(chartCalendar(utc))
        let runtime = makeChartRuntime(
            database: database,
            clock: clock,
            transport: ChartHTTPTransport { _ in HTTPResponse(statusCode: 500, body: Data()) },
            state: state,
            selection: chartSelection(source: .local, period: .week, now: now, calendar: calendarBox.calendar),
            calendarBox: calendarBox,
        )
        await runtime.start()
        try await runtime.charts?.saveCustomRange(
            start: ChartDate(2026, 10, 1),
            end: ChartDate(2026, 10, 14),
        )
        #expect(state.chartState.selection.source == .local)
        #expect(state.chartState.selection.period == .custom)

        await runtime.charts?.show()
        #expect(state.chartState.snapshot?.localTotal == 2, "the end date runs through its next midnight")

        await runtime.charts?.selectPeriod(.week)
        await runtime.charts?.selectSource(.service)
        #expect(state.chartState.selection.period == .week)
        #expect(state.chartState.selection.source == .service)
        await runtime.charts?.selectSavedCustomRange()
        #expect(state.chartState.selection.period == .custom)
        #expect(state.chartState.selection.source == .local)
        #expect(state.chartState.selection.customStart == ChartDate(2026, 10, 1))
        #expect(state.chartState.selection.customEnd == ChartDate(2026, 10, 14))
        await runtime.charts?.show()
        #expect(state.chartState.snapshot?.localTotal == 2)

        do {
            try await runtime.charts?.saveCustomRange(
                start: ChartDate(2026, 10, 14),
                end: ChartDate(2026, 10, 1),
            )
            Issue.record("A reversed Custom range was accepted")
        } catch {
            #expect(error as? ChartValidationError == .reversedCustomRange)
        }
    }

    /// Equal counts order by normalized key, with sequential ranks and a stable spelling.
    @Test func equalCountTieBreakUsesNormalizedKeyAndSequentialRanks() async throws {
        let database = try TemporaryDatabase()
        let now = chartDate(2026, 10, 31, 12)
        let clock = FakeClock(now)
        let store = try SQLiteListenStore(url: database.url)
        let spellings = ["Alpha", "  ALPHA  ", "beta", "Beta", "zeta"]
        for (index, artist) in spellings.enumerated() {
            try await store.insert(chartListen(
                title: "Song \(index)",
                artist: artist,
                album: "Album",
                startedAt: now.addingTimeInterval(Double(index)),
            ))
        }
        let state = TracklogAppState()
        let calendarBox = ChartCalendarBox(chartCalendar(utc))
        let runtime = makeChartRuntime(
            database: database,
            clock: clock,
            transport: ChartHTTPTransport { _ in HTTPResponse(statusCode: 500, body: Data()) },
            state: state,
            selection: chartSelection(source: .local, period: .allTime, now: now, calendar: calendarBox.calendar),
            calendarBox: calendarBox,
        )
        await runtime.start()
        await runtime.charts?.show()

        let snapshot = try #require(state.chartState.snapshot)
        #expect(snapshot.localTotal == 5)
        #expect(snapshot.omittedCount == 0)
        #expect(snapshot.items.map(\.title) == ["Alpha", "beta", "zeta"])
        #expect(snapshot.items.map(\.count) == [2, 2, 1])
        #expect(snapshot.items.map(\.rank) == [1, 2, 3])
        #expect(snapshot.items.map(\.identityKey) == ["alpha", "beta", "zeta"])

        let stored = try await store.page(limit: 10, before: nil)
        #expect(
            stored.contains { $0.processed.artist == "  ALPHA  " },
            "charts never rewrite the stored metadata identity",
        )
        #expect(stored.contains { $0.processed.artist == "Alpha" })
    }

    /// All-blank album data is its own state, and the range total still counts it.
    @Test func albumMissingMetadataIsItsOwnStateWithAnExactTotal() async throws {
        let database = try TemporaryDatabase()
        let now = chartDate(2026, 10, 31, 12)
        let clock = FakeClock(now)
        let store = try SQLiteListenStore(url: database.url)
        try await store.insert(chartListen(
            title: "No Album One",
            artist: "Artist One",
            album: "",
            albumArtist: "",
            startedAt: chartDate(2026, 10, 31, 9),
        ))
        try await store.insert(chartListen(
            title: "No Album Two",
            artist: "Artist Two",
            album: "   ",
            albumArtist: "  ",
            startedAt: chartDate(2026, 10, 31, 10),
        ))
        let state = TracklogAppState()
        let calendarBox = ChartCalendarBox(chartCalendar(utc))
        let runtime = makeChartRuntime(
            database: database,
            clock: clock,
            transport: ChartHTTPTransport { _ in HTTPResponse(statusCode: 500, body: Data()) },
            state: state,
            selection: chartSelection(
                source: .local,
                period: .custom,
                type: .albums,
                now: now,
                calendar: calendarBox.calendar,
                customStart: ChartDate(2026, 10, 31),
                customEnd: ChartDate(2026, 10, 31),
            ),
            calendarBox: calendarBox,
        )
        await runtime.start()
        await runtime.charts?.show()

        let snapshot = try #require(state.chartState.snapshot)
        #expect(snapshot.localTotal == 2, "every listen in the range is counted")
        #expect(snapshot.omittedCount == 2, "both records lack an album")
        #expect(snapshot.items.isEmpty)
        #expect(state.chartState.phase == .noMetadata(omitted: 2))
        #expect(state.chartState.totals == .local(2))
        #expect(state.chartState.phase != .empty)
    }

    /// The sign-in remedy must not claim saved charts when none exist.
    @Test func signInFailureCopyMatchesWhetherSavedChartsExist() {
        let withoutSaved = ChartCopy.signInFailureMessage(
            source: "Last.fm · listener",
            hasSavedCharts: false,
        )
        #expect(!withoutSaved.contains("saved charts stay visible"))
        #expect(withoutSaved.contains("local history"))

        let withSaved = ChartCopy.signInFailureMessage(
            source: "Last.fm · listener",
            hasSavedCharts: true,
        )
        #expect(withSaved.contains("saved charts stay visible"))
    }

    @Test func defaultTakeoverSectionIsHistoryAndSelectionPersists() async throws {
        let database = try TemporaryDatabase()
        let now = chartDate(2026, 10, 31, 12)
        let clock = FakeClock(now)
        let calendar = chartCalendar(utc)
        let state = TracklogAppState()
        let calendarBox = ChartCalendarBox(calendar)
        var persisted: [ChartSelection] = []
        let runtime = makeChartRuntime(
            database: database,
            clock: clock,
            transport: ChartHTTPTransport { _ in HTTPResponse(statusCode: 500, body: Data()) },
            state: state,
            selection: chartSelection(source: .service, period: .week, now: now, calendar: calendar),
            calendarBox: calendarBox,
            persistSelection: { persisted.append($0) },
        )
        #expect(state.takeoverSection == .history)
        await runtime.start()
        await runtime.charts?.selectSource(.local)
        await runtime.charts?.selectType(.tracks)
        await runtime.charts?.selectPeriod(.today)
        #expect(persisted.last?.source == .local)
        #expect(persisted.last?.type == .tracks)
        #expect(persisted.last?.period == .today)

        let reopened = try makeChartRuntime(
            database: database,
            clock: clock,
            transport: ChartHTTPTransport { _ in HTTPResponse(statusCode: 500, body: Data()) },
            state: TracklogAppState(),
            selection: #require(persisted.last),
            calendarBox: calendarBox,
        )
        #expect(reopened.charts?.selection == persisted.last)
    }
}

// MARK: - Fixtures

func chartListen(
    title: String,
    artist: String,
    album: String = "Album",
    albumArtist: String = "",
    bundleID: String = "com.apple.Music",
    startedAt: Date,
    artworkHash: String? = nil,
) -> Listen {
    let metadata = ListenMetadata(
        title: title,
        artist: artist,
        album: album,
        albumArtist: albumArtist,
    )
    return Listen(
        raw: metadata,
        processed: metadata,
        bundleID: bundleID,
        duration: 200,
        playedDuration: 100,
        startedAt: startedAt,
        capturedAt: startedAt.addingTimeInterval(100),
        artworkHash: artworkHash,
    )
}
