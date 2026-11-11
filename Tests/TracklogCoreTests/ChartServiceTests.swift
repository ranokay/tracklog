// swiftlint:disable file_length
import Foundation
import Testing
@testable import TracklogCore

@Suite("Chart service reads", .serialized)
@MainActor
// swiftlint:disable:next type_body_length
struct ChartServiceTests {
    private let utc = TimeZone(identifier: "UTC")!

    // swiftlint:disable:next function_body_length
    @Test func lastFMChartsUseRollingPeriodsAndProviderCounts() async throws {
        let database = try TemporaryDatabase()
        let now = chartDate(2026, 10, 31, 12)
        let clock = FakeClock(now)
        // swiftlint:disable:next large_tuple
        let artists: [(String, String, Int, String)] = [
            ("Blondie", "", 42, "artist-mbid"),
            ("Missing MBID", "", 7, ""),
        ]
        // swiftlint:disable:next large_tuple
        let albums: [(String, String, Int, String)] = [
            ("Parallel Lines", "Blondie", 30, "album-mbid"),
        ]
        // swiftlint:disable:next large_tuple
        let tracks: [(String, String, Int, String)] = [
            ("Heart of Glass", "Blondie", 20, "track-mbid"),
        ]
        let transport = ChartHTTPTransport { request in
            switch chartMethod(request) {
            case "user.getTopArtists":
                lastFMChartResponse(type: .artists, rows: artists)
            case "user.getTopAlbums":
                lastFMChartResponse(type: .albums, rows: albums)
            case "user.getTopTracks":
                lastFMChartResponse(type: .tracks, rows: tracks)
            case "user.getInfo":
                lastFMUserInfoResponse(playcount: 9_999)
            default:
                HTTPResponse(statusCode: 404, body: Data())
            }
        }
        let state = TracklogAppState()
        let calendarBox = ChartCalendarBox(chartCalendar(utc))
        let runtime = makeChartRuntime(
            database: database,
            clock: clock,
            transport: transport,
            state: state,
            selection: chartSelection(source: .service, period: .week, now: now, calendar: calendarBox.calendar),
            calendarBox: calendarBox,
        )
        await runtime.start()
        _ = try await runtime.link(kind: .lastFM, credential: "session-key")
        await runtime.charts?.show()

        let snapshot = try #require(state.chartState.snapshot)
        #expect(snapshot.countUnit == .plays)
        #expect(snapshot.returnedRange == nil)
        #expect(snapshot.items.count == 2)
        let first = try #require(snapshot.items.first)
        let second = try #require(snapshot.items.dropFirst().first)
        #expect(first.rank == 1)
        #expect(first.title == "Blondie")
        #expect(first.count == 42)
        #expect(second.providerID == nil)
        #expect(second.identityKey.hasPrefix("fallback:lastfm:"))
        #expect(state.chartState.periodDetail == "Rolling 7 days")
        #expect(ChartCopy.periodLabel(state.chartState, calendar: chartCalendar(utc)) == "Rolling 7 days")
        #expect(ChartCopy.listTitle(type: .artists, period: "Rolling 7 days") == "Top 50 artists · Rolling 7 days")
        #expect(ChartCopy.countUnit(1, .plays) == "play")
        #expect(ChartCopy.countUnit(2, .plays) == "plays")
        #expect(ChartCopy.rowAccessibilityLabel(
            rank: 1,
            title: "Blondie",
            subtitle: "",
            count: 1,
            unit: .plays,
        ) == "Rank 1, Blondie, 1 play")
        #expect(ChartCopy.rowAccessibilityValue(
            source: "Last.fm · listener",
            period: "Rolling 7 days",
        ) == "Last.fm · listener, Rolling 7 days")
        #expect(ChartCopy.totalLabel(
            count: 1,
            caption: "local listens",
            savedAt: now,
            age: "8 min ago",
        ) == "1 local listens, saved 8 min ago")
        #expect(state.chartState.totals == .unavailable(.rangeTotals))

        let chartRequests = await transport.recordedRequests.filter(chartIsLastFMTopRequest)
        #expect(chartRequests.count == 1)
        let parameters = try formParameters(#require(chartRequests.first))
        #expect(parameters["user"] == "listener")
        #expect(parameters["period"] == "7day")
        #expect(parameters["limit"] == "50")
        #expect(await transport.recordedRequests.filter { chartMethod($0) == "user.getInfo" }.count == 1)

        await runtime.charts?.selectType(.albums)
        let albumsSnapshot = try #require(state.chartState.snapshot)
        #expect(albumsSnapshot.type == .albums)
        #expect(albumsSnapshot.items.first?.title == "Parallel Lines")
        #expect(albumsSnapshot.items.first?.subtitle == "Blondie")

        await runtime.charts?.selectType(.tracks)
        let tracksSnapshot = try #require(state.chartState.snapshot)
        #expect(tracksSnapshot.type == .tracks)
        #expect(tracksSnapshot.items.first?.title == "Heart of Glass")

        await runtime.charts?.selectType(.artists)
        let typeRequests = await transport.recordedRequests.filter(chartIsLastFMTopRequest)
        for method in ["user.getTopArtists", "user.getTopAlbums", "user.getTopTracks"] {
            let request = try #require(typeRequests.last { chartMethod($0) == method })
            #expect(formParameters(request)["limit"] == "50")
            #expect(formParameters(request)["period"] == "7day")
        }
        await runtime.charts?.selectPeriod(.allTime)
        #expect(state.chartState.periodDetail == "All time")
        #expect(state.chartState.totals == .account(ChartAccountTotal(
            value: 9_999,
            serviceName: "Last.fm",
            savedAt: now,
        )))
        #expect(await transport.recordedRequests.filter { chartMethod($0) == "user.getInfo" }.count == 2)
    }

    // swiftlint:disable:next function_body_length
    @Test func listenBrainzChartsUseCompletedPeriodsAndReturnedDates() async throws {
        let database = try TemporaryDatabase()
        let now = chartDate(2026, 10, 31, 12)
        let clock = FakeClock(now)
        let from = chartDate(2026, 10, 20)
        let periodEnd = chartDate(2026, 10, 27)
        let updated = chartDate(2026, 10, 28, 6)
        let transport = ChartHTTPTransport { request in
            let bounds: (from: Date, end: Date) = switch chartQueryValue("range", in: request) {
            case "month": (chartDate(2026, 9, 1), chartDate(2026, 10, 1))
            case "year": (chartDate(2025, 1, 1), chartDate(2026, 1, 1))
            case "all_time": (chartDate(2002, 1, 1), chartDate(2026, 10, 28))
            default: (from, periodEnd)
            }
            if chartListenBrainzPath(request).hasSuffix("validate-token") {
                return listenBrainzValidResponse()
            }
            if chartListenBrainzPath(request).hasSuffix("listen-count") {
                return listenBrainzCountResponse(9_876)
            }
            if chartListenBrainzPath(request).contains("/artists") {
                return listenBrainzStatsResponse(
                    type: .artists,
                    rows: [
                        ("Blondie", "", 42, "artist-mbid"),
                        ("Missing MBID", "", 7, ""),
                    ],
                    from: bounds.from,
                    end: bounds.end,
                    lastUpdated: updated,
                )
            }
            if chartListenBrainzPath(request).contains("/releases") {
                return listenBrainzStatsResponse(
                    type: .albums,
                    rows: [("Parallel Lines", "Blondie", 30, "release-mbid")],
                    from: bounds.from,
                    end: bounds.end,
                    lastUpdated: updated,
                )
            }
            if chartListenBrainzPath(request).contains("/recordings") {
                return listenBrainzStatsResponse(
                    type: .tracks,
                    rows: [("Heart of Glass", "Blondie", 20, "recording-mbid")],
                    from: bounds.from,
                    end: bounds.end,
                    lastUpdated: updated,
                )
            }
            return HTTPResponse(statusCode: 404, body: Data())
        }
        let state = TracklogAppState()
        let calendarBox = ChartCalendarBox(chartCalendar(utc))
        let runtime = makeChartRuntime(
            database: database,
            clock: clock,
            transport: transport,
            state: state,
            selection: chartSelection(source: .service, period: .week, now: now, calendar: calendarBox.calendar),
            calendarBox: calendarBox,
        )
        await runtime.start()
        _ = try await runtime.link(kind: .listenBrainz, credential: "secret-token")
        await runtime.charts?.show()

        let snapshot = try #require(state.chartState.snapshot)
        #expect(snapshot.countUnit == .listens)
        #expect(
            snapshot.items.count == 2,
            "phase: \(state.chartState.phase), refresh: \(String(describing: state.chartState.refreshFailure))",
        )
        let first = try #require(snapshot.items.first)
        let second = try #require(snapshot.items.dropFirst().first)
        #expect(first.count == 42)
        #expect(snapshot.returnedRange?.start == from)
        #expect(snapshot.returnedRange?.end == periodEnd)
        #expect(snapshot.returnedRange?.lastUpdated == updated)
        #expect(second.providerID == nil)
        #expect(second.identityKey.hasPrefix("fallback:listenbrainz:"))
        #expect(state.chartState.periodDetail == "Previous completed week")
        #expect(ChartCopy.periodLabel(state.chartState, calendar: chartCalendar(utc)) == "Previous completed week")
        #expect(ChartCopy.countUnit(1, .listens) == "listen")
        #expect(ChartCopy.rowAccessibilityValue(
            source: "ListenBrainz · listener",
            period: "Previous completed week",
        ) == "ListenBrainz · listener, Previous completed week")
        #expect(state.chartState.totals == .unavailable(.rangeTotals))

        let statsRequest = try #require(
            await transport.recordedRequests.first { chartListenBrainzPath($0).contains("/stats/user/") },
        )
        #expect(statsRequest.headers["Authorization"] == "Token secret-token")
        #expect(chartQueryValue("range", in: statsRequest) == "week")
        #expect(chartQueryValue("count", in: statsRequest) == "50")
        #expect(chartQueryValue("offset", in: statsRequest) == "0")

        // swiftlint:disable:next large_tuple
        let expectedBounds: [(ChartPeriod, String, Date, Date)] = [
            (.month, "month", chartDate(2026, 9, 1), chartDate(2026, 10, 1)),
            (.year, "year", chartDate(2025, 1, 1), chartDate(2026, 1, 1)),
            (.allTime, "all_time", chartDate(2002, 1, 1), chartDate(2026, 10, 28)),
        ]
        for (period, value, expectedFrom, expectedEnd) in expectedBounds {
            await runtime.charts?.selectPeriod(period)
            let request = try #require(
                await transport.recordedRequests.last { chartListenBrainzPath($0).contains("/stats/user/") },
            )
            #expect(chartQueryValue("range", in: request) == value)
            #expect(state.chartState.snapshot?.returnedRange?.start == expectedFrom)
            #expect(state.chartState.snapshot?.returnedRange?.end == expectedEnd)
        }
        #expect(state.chartState.totals == .account(ChartAccountTotal(
            value: 9_876,
            serviceName: "ListenBrainz",
            savedAt: now,
        )))
        #expect(state.chartState.snapshot?.items.count == 2)

        await runtime.charts?.selectType(.albums)
        #expect(state.chartState.snapshot?.items.first?.title == "Parallel Lines")
        await runtime.charts?.selectType(.tracks)
        #expect(state.chartState.snapshot?.items.first?.title == "Heart of Glass")

        let payloads = try await SQLiteListenStore(url: database.url).chartCachePayloads()
        #expect(!payloads.contains { data in
            // swiftlint:disable:next optional_data_string_conversion
            String(decoding: data, as: UTF8.self).contains("secret-token")
        }, "no credential enters a chart cache")
    }

    @Test func notReadyAndEmptyAreDistinct() async throws {
        let noData = try await serviceRead(
            type: .artists,
            handler: { request in
                if chartListenBrainzPath(request).hasSuffix("validate-token") {
                    return listenBrainzValidResponse()
                }
                return HTTPResponse(statusCode: 204, body: Data())
            },
        )
        #expect(noData.state.chartState.phase == .notReady)
        #expect(noData.state.chartState.snapshot == nil)

        let empty = try await serviceRead(
            type: .artists,
            handler: { request in
                if chartListenBrainzPath(request).hasSuffix("validate-token") {
                    return listenBrainzValidResponse()
                }
                return listenBrainzEmptyResponse(type: .artists)
            },
        )
        #expect(empty.state.chartState.phase == .empty)
        #expect(empty.state.chartState.snapshot?.items.isEmpty == true)
    }

    @Test func libreFMOffersNamedLocalFallbackWithoutARequest() async throws {
        let database = try TemporaryDatabase()
        let now = chartDate(2026, 10, 31, 12)
        let clock = FakeClock(now)
        let store = try SQLiteListenStore(url: database.url)
        _ = try await store.insert(chartListen(title: "Local", artist: "Artist", startedAt: now))
        let transport = ChartHTTPTransport { _ in
            HTTPResponse(statusCode: 500, body: Data())
        }
        let state = TracklogAppState()
        let calendarBox = ChartCalendarBox(chartCalendar(utc))
        let runtime = makeChartRuntime(
            database: database,
            clock: clock,
            transport: transport,
            state: state,
            selection: chartSelection(source: .service, period: .week, now: now, calendar: calendarBox.calendar),
            calendarBox: calendarBox,
        )
        await runtime.start()
        _ = try await runtime.link(kind: .libreFM, credential: "token")
        await runtime.charts?.show()

        #expect(state.chartState.effectiveSource == .local(reason: .unsupported(.libreFM)))
        #expect(state.chartState.snapshot?.items.first?.title == "Artist")
        #expect(state.chartState.snapshot?.localTotal == 1)
        #expect(await transport.requestCount() == 0)

        await runtime.charts?.selectPeriod(.today)
        #expect(state.chartState.selection.period == .today)
        #expect(state.chartState.effectiveSource.isLocal)
        #expect(state.chartState.snapshot?.localTotal == 1)
    }

    @Test func aServiceSelectionWithoutAConnectionShowsNoConnection() async throws {
        let database = try TemporaryDatabase()
        let now = chartDate(2026, 10, 31, 12)
        let clock = FakeClock(now)
        let state = TracklogAppState()
        let calendarBox = ChartCalendarBox(chartCalendar(utc))
        let runtime = makeChartRuntime(
            database: database,
            clock: clock,
            transport: ChartHTTPTransport { _ in HTTPResponse(statusCode: 500, body: Data()) },
            state: state,
            selection: chartSelection(source: .service, period: .week, now: now, calendar: calendarBox.calendar),
            calendarBox: calendarBox,
        )
        await runtime.start()
        await runtime.charts?.show()
        #expect(state.chartState.phase == .noConnection)
        #expect(state.chartState.snapshot == nil)
    }

    @Test func lastFMSingleItemObjectResponsesDecode() async throws {
        let database = try TemporaryDatabase()
        let now = chartDate(2026, 10, 31, 12)
        let clock = FakeClock(now)
        let transport = ChartHTTPTransport { request in
            switch chartMethod(request) {
            case "user.getTopArtists":
                lastFMSingleChartResponse(type: .artists)
            case "user.getTopAlbums":
                lastFMSingleChartResponse(type: .albums)
            case "user.getTopTracks":
                lastFMSingleChartResponse(type: .tracks)
            case "user.getInfo":
                lastFMUserInfoResponse()
            default:
                HTTPResponse(statusCode: 404, body: Data())
            }
        }
        let state = TracklogAppState()
        let calendarBox = ChartCalendarBox(chartCalendar(utc))
        let runtime = makeChartRuntime(
            database: database,
            clock: clock,
            transport: transport,
            state: state,
            selection: chartSelection(source: .service, period: .week, now: now, calendar: calendarBox.calendar),
            calendarBox: calendarBox,
        )
        await runtime.start()
        _ = try await runtime.link(kind: .lastFM, credential: "session-key")
        await runtime.charts?.show()
        #expect(state.chartState.snapshot?.items.count == 1)
        #expect(state.chartState.snapshot?.items.first?.title == "Solo Artists")

        await runtime.charts?.selectType(.albums)
        #expect(state.chartState.snapshot?.items.first?.title == "Solo Albums")
        await runtime.charts?.selectType(.tracks)
        #expect(state.chartState.snapshot?.items.first?.title == "Solo Tracks")
    }

    @Test func lastFMAppCredentialFailureIsDistinctFromAnAccountFailure() async throws {
        let database = try TemporaryDatabase()
        let now = chartDate(2026, 10, 31, 12)
        let clock = FakeClock(now)
        let transport = ChartHTTPTransport { request in
            switch chartMethod(request) {
            case "user.getTopArtists":
                lastFMErrorResponse(code: 10, message: "Invalid API key")
            case "user.getInfo":
                lastFMUserInfoResponse()
            default:
                HTTPResponse(statusCode: 404, body: Data())
            }
        }
        let state = TracklogAppState()
        let calendarBox = ChartCalendarBox(chartCalendar(utc))
        let runtime = makeChartRuntime(
            database: database,
            clock: clock,
            transport: transport,
            state: state,
            selection: chartSelection(source: .service, period: .week, now: now, calendar: calendarBox.calendar),
            calendarBox: calendarBox,
        )
        await runtime.start()
        _ = try await runtime.link(kind: .lastFM, credential: "session-key")
        await runtime.charts?.show()
        #expect(state.chartState.phase == .failed(.appCredentials))
    }

    @Test func listenBrainzRateLimitIsNotOffline() async throws {
        let database = try TemporaryDatabase()
        let now = chartDate(2026, 10, 31, 12)
        let clock = FakeClock(now)
        let transport = ChartHTTPTransport { request in
            if chartListenBrainzPath(request).hasSuffix("validate-token") {
                return listenBrainzValidResponse()
            }
            return HTTPResponse(
                statusCode: 429,
                headers: ["Retry-After": "30"],
                body: Data(),
            )
        }
        let state = TracklogAppState()
        let calendarBox = ChartCalendarBox(chartCalendar(utc))
        let runtime = makeChartRuntime(
            database: database,
            clock: clock,
            transport: transport,
            state: state,
            selection: chartSelection(source: .service, period: .week, now: now, calendar: calendarBox.calendar),
            calendarBox: calendarBox,
        )
        await runtime.start()
        _ = try await runtime.link(kind: .listenBrainz, credential: "token")
        await runtime.charts?.show()
        #expect(state.chartState.phase == .failed(.rateLimited(retryAfter: 30)))
    }

    @Test func lastFMChartPeriodsUseNativeRollingValues() async throws {
        let database = try TemporaryDatabase()
        let now = chartDate(2026, 10, 31, 12)
        let clock = FakeClock(now)
        let transport = ChartHTTPTransport { request in
            switch chartMethod(request) {
            case "user.getTopArtists":
                lastFMChartResponse(type: .artists, rows: [("Blondie", "", 42, "artist-mbid")])
            case "user.getInfo":
                lastFMUserInfoResponse(playcount: 9_999)
            default:
                HTTPResponse(statusCode: 404, body: Data())
            }
        }
        let state = TracklogAppState()
        let calendarBox = ChartCalendarBox(chartCalendar(utc))
        let runtime = makeChartRuntime(
            database: database,
            clock: clock,
            transport: transport,
            state: state,
            selection: chartSelection(source: .service, period: .week, now: now, calendar: calendarBox.calendar),
            calendarBox: calendarBox,
        )
        await runtime.start()
        _ = try await runtime.link(kind: .lastFM, credential: "session-key")
        await runtime.charts?.show()
        for period in [ChartPeriod.month, .year, .allTime] {
            await runtime.charts?.selectPeriod(period)
        }

        let requests = await transport.recordedRequests.filter(chartIsLastFMTopRequest)
        #expect(requests.count == 4)
        #expect(requests.compactMap { formParameters($0)["period"] } == ["7day", "1month", "12month", "overall"])
        for request in requests {
            #expect(formParameters(request)["limit"] == "50")
            #expect(formParameters(request)["user"] == "listener")
        }
    }

    @Test func lastFMChartKeepsTheFirstFiftyProviderRows() async throws {
        let database = try TemporaryDatabase()
        let now = chartDate(2026, 10, 31, 12)
        let clock = FakeClock(now)
        // swiftlint:disable:next large_tuple
        let rows: [(String, String, Int, String)] = (0 ..< 51).map { index in
            (
                "Artist \(index + 1)",
                "",
                index == 1 ? 999 : 100 - index,
                index == 1 ? "" : "mbid-\(index + 1)",
            )
        }
        let transport = ChartHTTPTransport { request in
            switch chartMethod(request) {
            case "user.getTopArtists":
                lastFMChartResponse(type: .artists, rows: rows)
            case "user.getInfo":
                lastFMUserInfoResponse()
            default:
                HTTPResponse(statusCode: 404, body: Data())
            }
        }
        let state = TracklogAppState()
        let calendarBox = ChartCalendarBox(chartCalendar(utc))
        let runtime = makeChartRuntime(
            database: database,
            clock: clock,
            transport: transport,
            state: state,
            selection: chartSelection(source: .service, period: .week, now: now, calendar: calendarBox.calendar),
            calendarBox: calendarBox,
        )
        await runtime.start()
        _ = try await runtime.link(kind: .lastFM, credential: "session-key")
        await runtime.charts?.show()

        let snapshot = try #require(state.chartState.snapshot)
        #expect(snapshot.items.count == 50, "the first 50 returned entities are kept")
        #expect(snapshot.items.map(\.rank) == Array(1 ... 50), "provider rank is preserved")
        #expect(snapshot.items.first?.title == "Artist 1", "provider order is not re-sorted by count")
        #expect(snapshot.items.first?.count == 100)
        #expect(snapshot.items.last?.title == "Artist 50")
        #expect(!snapshot.items.contains { $0.title == "Artist 51" })
        let missingID = try #require(snapshot.items.dropFirst().first)
        #expect(missingID.providerID == nil)
        #expect(missingID.identityKey.hasPrefix("fallback:lastfm:artists:"))
    }

    @Test func lastFMChartCapsEveryEntityTypeAtFifty() async throws {
        let database = try TemporaryDatabase()
        let now = chartDate(2026, 10, 31, 12)
        let clock = FakeClock(now)
        // swiftlint:disable:next large_tuple
        let artistRows: [(String, String, Int, String)] = (0 ..< 51).map { index in
            ("Artist \(index + 1)", "", 100 - index, "artist-\(index + 1)")
        }
        // swiftlint:disable:next large_tuple
        let albumRows: [(String, String, Int, String)] = (0 ..< 51).map { index in
            ("Album \(index + 1)", "Artist \(index + 1)", 100 - index, "album-\(index + 1)")
        }
        // swiftlint:disable:next large_tuple
        let trackRows: [(String, String, Int, String)] = (0 ..< 51).map { index in
            ("Track \(index + 1)", "Artist \(index + 1)", 100 - index, "track-\(index + 1)")
        }
        let transport = ChartHTTPTransport { request in
            switch chartMethod(request) {
            case "user.getTopArtists":
                lastFMChartResponse(type: .artists, rows: artistRows)
            case "user.getTopAlbums":
                lastFMChartResponse(type: .albums, rows: albumRows)
            case "user.getTopTracks":
                lastFMChartResponse(type: .tracks, rows: trackRows)
            case "user.getInfo":
                lastFMUserInfoResponse()
            default:
                HTTPResponse(statusCode: 404, body: Data())
            }
        }
        let state = TracklogAppState()
        let calendarBox = ChartCalendarBox(chartCalendar(utc))
        let runtime = makeChartRuntime(
            database: database,
            clock: clock,
            transport: transport,
            state: state,
            selection: chartSelection(source: .service, period: .week, now: now, calendar: calendarBox.calendar),
            calendarBox: calendarBox,
        )
        await runtime.start()
        _ = try await runtime.link(kind: .lastFM, credential: "session-key")
        await runtime.charts?.show()

        for type in ChartType.allCases {
            await runtime.charts?.selectType(type)
            let snapshot = try #require(state.chartState.snapshot)
            #expect(snapshot.type == type)
            #expect(snapshot.items.count == 50, "\(type) keeps only the first 50 returned entities")
            #expect(snapshot.items.map(\.rank) == Array(1 ... 50))
            #expect(snapshot.items.first?.title.hasSuffix("1") == true)
            #expect(snapshot.items.last?.title.hasSuffix("50") == true)
        }
    }

    @Test func lastFMChartKeepsProviderRanksAndNamedFallbackIDs() async throws {
        let database = try TemporaryDatabase()
        let now = chartDate(2026, 10, 31, 12)
        let clock = FakeClock(now)
        let transport = ChartHTTPTransport { request in
            switch chartMethod(request) {
            case "user.getTopArtists":
                lastFMChartResponse(
                    type: .artists,
                    rows: [("First", "", 1, "mbid-first"), ("Second", "", 999, "")],
                    ranks: [7, 2],
                )
            case "user.getInfo":
                lastFMUserInfoResponse()
            default:
                HTTPResponse(statusCode: 404, body: Data())
            }
        }
        let state = TracklogAppState()
        let calendarBox = ChartCalendarBox(chartCalendar(utc))
        let runtime = makeChartRuntime(
            database: database,
            clock: clock,
            transport: transport,
            state: state,
            selection: chartSelection(source: .service, period: .week, now: now, calendar: calendarBox.calendar),
            calendarBox: calendarBox,
        )
        await runtime.start()
        _ = try await runtime.link(kind: .lastFM, credential: "session-key")
        await runtime.charts?.show()

        let items = try #require(state.chartState.snapshot?.items)
        #expect(items.map(\.rank) == [7, 2], "the provider's rank is kept, not the array index")
        #expect(items.first?.title == "First", "provider order is kept even when its count is lower")
        #expect(items.first?.identityKey == "mbid:mbid-first")
        #expect(items.dropFirst().first?.providerID == nil)
        #expect(items.dropFirst().first?.identityKey.hasPrefix("fallback:lastfm:artists:") == true)
    }

    @Test func lastFMChartRateLimitIsNotOffline() async throws {
        let database = try TemporaryDatabase()
        let now = chartDate(2026, 10, 31, 12)
        let clock = FakeClock(now)
        let transport = ChartHTTPTransport { request in
            switch chartMethod(request) {
            case "user.getTopArtists":
                lastFMErrorResponse(code: 29, message: "Rate limit exceeded")
            case "user.getInfo":
                lastFMUserInfoResponse()
            default:
                HTTPResponse(statusCode: 404, body: Data())
            }
        }
        let state = TracklogAppState()
        let calendarBox = ChartCalendarBox(chartCalendar(utc))
        let runtime = makeChartRuntime(
            database: database,
            clock: clock,
            transport: transport,
            state: state,
            selection: chartSelection(source: .service, period: .week, now: now, calendar: calendarBox.calendar),
            calendarBox: calendarBox,
        )
        await runtime.start()
        _ = try await runtime.link(kind: .lastFM, credential: "session-key")
        await runtime.charts?.show()

        #expect(state.chartState.phase == .failed(.rateLimited(retryAfter: nil)))
        #expect(state.chartState.snapshot == nil)
    }

    @Test func serviceChartsClampTodayAndCustomToWeek() async throws {
        for period in [ChartPeriod.today, .custom] {
            let database = try TemporaryDatabase()
            let now = chartDate(2026, 10, 31, 12)
            let clock = FakeClock(now)
            let transport = ChartHTTPTransport { request in
                switch chartMethod(request) {
                case "user.getTopArtists":
                    lastFMChartResponse(type: .artists, rows: [("Blondie", "", 42, "artist-mbid")])
                case "user.getInfo":
                    lastFMUserInfoResponse()
                default:
                    HTTPResponse(statusCode: 404, body: Data())
                }
            }
            let state = TracklogAppState()
            let calendarBox = ChartCalendarBox(chartCalendar(utc))
            let runtime = makeChartRuntime(
                database: database,
                clock: clock,
                transport: transport,
                state: state,
                selection: chartSelection(
                    source: .service,
                    period: period,
                    now: now,
                    calendar: calendarBox.calendar,
                ),
                calendarBox: calendarBox,
            )
            await runtime.start()
            _ = try await runtime.link(kind: .lastFM, credential: "session-key")
            await runtime.charts?.show()

            #expect(state.chartState.selection.period == .week, "\(period) is local-only")
            let request = try #require(
                await transport.recordedRequests.last(where: chartIsLastFMTopRequest),
            )
            #expect(formParameters(request)["period"] == "7day")
        }
    }

    @Test func allTimeListSucceedsWhenTheTotalFails() async throws {
        let database = try TemporaryDatabase()
        let now = chartDate(2026, 10, 31, 12)
        let clock = FakeClock(now)
        let transport = ChartHTTPTransport { request in
            let path = chartListenBrainzPath(request)
            if path.hasSuffix("validate-token") {
                return listenBrainzValidResponse()
            }
            if path.contains("/stats/user/") {
                return listenBrainzStatsResponse(
                    type: .artists,
                    rows: [("Blondie", "", 42, "artist-mbid")],
                    from: chartDate(2026, 10, 20),
                    end: chartDate(2026, 10, 27),
                    lastUpdated: chartDate(2026, 10, 28, 6),
                )
            }
            return HTTPResponse(statusCode: 500, body: Data())
        }
        let state = TracklogAppState()
        let calendarBox = ChartCalendarBox(chartCalendar(utc))
        let runtime = makeChartRuntime(
            database: database,
            clock: clock,
            transport: transport,
            state: state,
            selection: chartSelection(source: .service, period: .allTime, now: now, calendar: calendarBox.calendar),
            calendarBox: calendarBox,
        )
        await runtime.start()
        _ = try await runtime.link(kind: .listenBrainz, credential: "token")
        await runtime.charts?.show()

        #expect(state.chartState.phase == .ready)
        #expect(state.chartState.snapshot?.items.first?.title == "Blondie")
        #expect(state.chartState.totals == .unavailable(.accountTotal(.offline)))
        #expect(state.chartState.totalFailure == .offline)
    }

    @Test func allTimeTotalSucceedsWhenTheListFails() async throws {
        let database = try TemporaryDatabase()
        let now = chartDate(2026, 10, 31, 12)
        let clock = FakeClock(now)
        let transport = ChartHTTPTransport { request in
            let path = chartListenBrainzPath(request)
            if path.hasSuffix("validate-token") {
                return listenBrainzValidResponse()
            }
            if path.contains("/stats/user/") {
                return HTTPResponse(statusCode: 401, body: Data())
            }
            if path.contains("listen-count") {
                return listenBrainzCountResponse(9_876)
            }
            return HTTPResponse(statusCode: 404, body: Data())
        }
        let state = TracklogAppState()
        let calendarBox = ChartCalendarBox(chartCalendar(utc))
        let runtime = makeChartRuntime(
            database: database,
            clock: clock,
            transport: transport,
            state: state,
            selection: chartSelection(source: .service, period: .allTime, now: now, calendar: calendarBox.calendar),
            calendarBox: calendarBox,
        )
        await runtime.start()
        _ = try await runtime.link(kind: .listenBrainz, credential: "token")
        await runtime.charts?.show()

        #expect(state.chartState.phase == .failed(.needsSignIn))
        #expect(state.chartState.snapshot == nil)
        #expect(state.chartState.totals == .account(ChartAccountTotal(
            value: 9_876,
            serviceName: "ListenBrainz",
            savedAt: now,
        )))
        #expect(state.chartState.totalFailure == nil)
    }

    @Test func changingTheReadCursorDoesNotChangeDeliveryTargets() async throws {
        let database = try TemporaryDatabase()
        let now = chartDate(2026, 10, 31, 12)
        let clock = FakeClock(now)
        let transport = ChartHTTPTransport { request in
            let path = chartListenBrainzPath(request)
            if path.hasSuffix("validate-token") {
                return listenBrainzValidResponse()
            }
            if chartMethod(request) == "user.getInfo" {
                return lastFMUserInfoResponse()
            }
            if chartMethod(request) == "user.getTopArtists" {
                return lastFMChartResponse(type: .artists, rows: [("Blondie", "", 42, "artist-mbid")])
            }
            if path.contains("/stats/user/") {
                return listenBrainzStatsResponse(
                    type: .artists,
                    rows: [("Talking Heads", "", 30, "artist-mbid-2")],
                    from: chartDate(2026, 10, 20),
                    end: chartDate(2026, 10, 27),
                    lastUpdated: chartDate(2026, 10, 28, 6),
                )
            }
            if path.contains("listen-count") {
                return listenBrainzCountResponse(500)
            }
            if chartMethod(request) == "track.scrobble" {
                return lastFMScrobbleResponse(codes: [0])
            }
            if chartMethod(request) == "track.updateNowPlaying" || path.contains("submit-listens") {
                return chartJSONResponse(["status": "ok"])
            }
            return HTTPResponse(statusCode: 404, body: Data())
        }
        let state = TracklogAppState()
        let calendarBox = ChartCalendarBox(chartCalendar(utc))
        let runtime = makeChartRuntime(
            database: database,
            clock: clock,
            transport: transport,
            state: state,
            selection: chartSelection(source: .service, period: .week, now: now, calendar: calendarBox.calendar),
            calendarBox: calendarBox,
            scrobblingEnabled: true,
        )
        let store = try SQLiteListenStore(url: database.url)
        await runtime.start()
        let brainz = try await runtime.link(kind: .listenBrainz, credential: "token")
        let lastFM = try await runtime.link(kind: .lastFM, credential: "session-key")
        try await runtime.setCurrentConnection(lastFM.id)
        await runtime.charts?.show()
        #expect(state.chartState.snapshot?.items.first?.title == "Blondie")

        try await runtime.setCurrentConnection(brainz.id)
        await runtime.charts?.show()
        #expect(state.chartState.snapshot?.items.first?.title == "Talking Heads")
        #expect(state.connections.filter(\.isEnabled).count == 2)

        let track = Track(
            title: "Cursor Continuity",
            artist: "Blondie",
            album: "Parallel Lines",
            duration: 30,
            bundleID: "com.apple.Music",
        )
        for second in stride(from: 0.0, through: 30.0, by: 2.0) {
            clock.now = now.addingTimeInterval(second)
            await runtime.ingest(MediaSample(
                track: track,
                elapsed: second,
                playbackRate: 1,
                isPlaying: true,
                timestamp: clock.now,
            ))
        }
        let listen = try #require(state.listens.first { $0.processed.title == "Cursor Continuity" })
        let deliveries = try await store.deliveries(for: listen.id ?? -1)
        #expect(
            Set(deliveries.map(\.connectionID)) == Set([brainz.id, lastFM.id].compactMap(\.self)),
            "the chart cursor selected a source, not the delivery target set",
        )
    }

    @Test func aLateServiceResponseAfterSourceChangeCannotOverwriteLocalCharts() async throws {
        let database = try TemporaryDatabase()
        let now = chartDate(2026, 10, 31, 12)
        let clock = FakeClock(now)
        let gate = ChartHoldGate()
        let flags = ChartFlags()
        let transport = listenBrainzTransport(flags: flags, gate: gate)
        let store = try SQLiteListenStore(url: database.url)
        _ = try await store.insert(chartListen(title: "Local Song", artist: "Local Artist", startedAt: now))
        let state = TracklogAppState()
        let calendarBox = ChartCalendarBox(chartCalendar(utc))
        let runtime = makeChartRuntime(
            database: database,
            clock: clock,
            transport: transport,
            state: state,
            selection: chartSelection(source: .service, period: .week, now: now, calendar: calendarBox.calendar),
            calendarBox: calendarBox,
        )
        await runtime.start()
        _ = try await runtime.link(kind: .listenBrainz, credential: "token")

        await gate.startHolding()
        let show = Task { await runtime.charts?.show() }
        #expect(await gate.waitUntilEntered(1), "the service read is held")
        await runtime.charts?.selectSource(.local)
        #expect(state.chartState.effectiveSource.isLocal)
        #expect(state.chartState.snapshot?.localTotal == 1)
        await gate.release()
        await show.value

        #expect(state.chartState.effectiveSource.isLocal)
        #expect(state.chartState.snapshot?.items.first?.title == "Local Artist")
        #expect(try await store.chartCacheCount() == 1, "only the local row is cached")
    }

    @Test func aLateResponseAfterPeriodChangeCannotBecomeCurrentOrBeCached() async throws {
        let database = try TemporaryDatabase()
        let now = chartDate(2026, 10, 31, 12)
        let clock = FakeClock(now)
        let flags = ChartFlags()
        let gate = ChartHoldGate()
        let transport = listenBrainzTransport(flags: flags, gate: gate)
        let store = try SQLiteListenStore(url: database.url)
        let state = TracklogAppState()
        let calendarBox = ChartCalendarBox(chartCalendar(utc))
        let runtime = makeChartRuntime(
            database: database,
            clock: clock,
            transport: transport,
            state: state,
            selection: chartSelection(source: .service, period: .week, now: now, calendar: calendarBox.calendar),
            calendarBox: calendarBox,
        )
        await runtime.start()
        _ = try await runtime.link(kind: .listenBrainz, credential: "token")

        await gate.startHolding()
        let show = Task { await runtime.charts?.show() }
        #expect(await gate.waitUntilEntered(1), "the week read is held")
        let switchPeriod = Task { await runtime.charts?.selectPeriod(.month) }
        #expect(await gate.waitUntilEntered(2), "the month read is held")
        await gate.release()
        await show.value
        await switchPeriod.value

        #expect(state.chartState.snapshot?.period == .month)
        #expect(state.chartState.snapshot?.items.first?.title == "Blondie")
        #expect(try await store.chartCacheCount() == 1, "the obsolete week response was never stored")
    }

    @Test func delayedLastFMChartWorkDoesNotBlockCaptureOrDelivery() async throws {
        let database = try TemporaryDatabase()
        let now = chartDate(2026, 10, 31, 12)
        let clock = FakeClock(now)
        let gate = ChartHoldGate()
        let transport = ChartHTTPTransport { request in
            switch chartMethod(request) {
            case "user.getInfo":
                return lastFMUserInfoResponse()
            case "user.getTopArtists":
                await gate.enter()
                return lastFMChartResponse(type: .artists, rows: [("Blondie", "", 42, "artist-mbid")])
            case "track.updateNowPlaying":
                return chartJSONResponse([:])
            case "track.scrobble":
                return lastFMScrobbleResponse(codes: [0])
            default:
                return HTTPResponse(statusCode: 404, body: Data())
            }
        }
        let state = TracklogAppState()
        let calendarBox = ChartCalendarBox(chartCalendar(utc))
        let runtime = makeChartRuntime(
            database: database,
            clock: clock,
            transport: transport,
            state: state,
            selection: chartSelection(source: .service, period: .week, now: now, calendar: calendarBox.calendar),
            calendarBox: calendarBox,
            scrobblingEnabled: true,
        )
        let store = try SQLiteListenStore(url: database.url)
        await runtime.start()
        _ = try await runtime.link(kind: .lastFM, credential: "session-key")

        await gate.startHolding()
        let show = Task { await runtime.charts?.show() }
        #expect(await gate.waitUntilEntered(1), "the Last.fm chart read is held")
        #expect(state.chartState.phase == .loading)

        let track = Track(
            title: "Last.fm Continuity",
            artist: "Blondie",
            album: "Parallel Lines",
            duration: 30,
            bundleID: "com.apple.Music",
        )
        for second in stride(from: 0.0, through: 30.0, by: 2.0) {
            clock.now = now.addingTimeInterval(second)
            await runtime.ingest(MediaSample(
                track: track,
                elapsed: second,
                playbackRate: 1,
                isPlaying: true,
                timestamp: clock.now,
            ))
        }
        #expect(state.nowPlaying?.track.title == "Last.fm Continuity")
        let listen = try #require(state.listens.first { $0.processed.title == "Last.fm Continuity" })
        #expect(state.historyCount == 1)
        clock.advance(to: clock.now.addingTimeInterval(2))
        let delivered = await chartWaitForDelivery(store, listenID: listen.id ?? -1)
        #expect(delivered?.state == .delivered, "the Last.fm delivery progressed while charts were held")
        #expect(await transport.recordedRequests.contains { chartMethod($0) == "track.scrobble" })
        #expect(state.chartState.phase == .loading, "capture and delivery did not wait for charts")

        await gate.release()
        await show.value
        #expect(state.chartState.snapshot?.items.first?.title == "Blondie")
        #expect(state.listens.contains { $0.processed.title == "Last.fm Continuity" })
    }

    @Test func lastFMAllTimeRowsStayReadyWhenTheAccountTotalFails() async throws {
        let database = try TemporaryDatabase()
        let now = chartDate(2026, 10, 31, 12)
        let clock = FakeClock(now)
        let flags = ChartFlags()
        let transport = ChartHTTPTransport { request in
            switch chartMethod(request) {
            case "user.getTopArtists":
                return lastFMChartResponse(type: .artists, rows: [("Blondie", "", 42, "artist-mbid")])
            case "user.getInfo":
                if await flags.isFailing() {
                    return HTTPResponse(statusCode: 500, body: Data())
                }
                return lastFMUserInfoResponse(playcount: 9_999)
            default:
                return HTTPResponse(statusCode: 404, body: Data())
            }
        }
        let state = TracklogAppState()
        let calendarBox = ChartCalendarBox(chartCalendar(utc))
        let runtime = makeChartRuntime(
            database: database,
            clock: clock,
            transport: transport,
            state: state,
            selection: chartSelection(source: .service, period: .allTime, now: now, calendar: calendarBox.calendar),
            calendarBox: calendarBox,
        )
        await runtime.start()
        _ = try await runtime.link(kind: .lastFM, credential: "session-key")
        let infoAfterLink = await lastFMUserInfoRequestCount(transport)

        await flags.setFailing(true)
        await runtime.charts?.show()
        #expect(state.chartState.phase == .ready)
        let snapshot = try #require(state.chartState.snapshot)
        #expect(snapshot.items.first?.title == "Blondie")
        #expect(snapshot.items.first?.identityKey == "mbid:artist-mbid")
        #expect(snapshot.countUnit == .plays)
        #expect(snapshot.localTotal == nil, "Last.fm never invents a list-derived period total")
        #expect(state.chartState.totals == .unavailable(.accountTotal(.offline)))
        #expect(state.chartState.totalFailure == .offline)
        let infoAfterFailedTotal = await lastFMUserInfoRequestCount(transport)
        #expect(infoAfterFailedTotal == infoAfterLink + 1, "the list succeeded with one failed total attempt")
        let topAfterShow = await lastFMTopRequestCount(transport)
        #expect(topAfterShow == 1)

        clock.advance(to: now.addingTimeInterval(ChartFreshness.interval))
        #expect(await chartWaitUntil {
            state.chartState.snapshot?.savedAt == clock.now
        }, "the healthy list refreshed at its own deadline")
        let topAfterAutomatic = await lastFMTopRequestCount(transport)
        #expect(topAfterAutomatic == topAfterShow + 1)
        #expect(
            await lastFMUserInfoRequestCount(transport) == infoAfterFailedTotal,
            "the failed account total was not retried automatically",
        )
        #expect(state.chartState.totals == .unavailable(.accountTotal(.offline)))
        #expect(state.chartState.totalFailure == .offline)
        #expect(state.chartState.snapshot?.items.first?.identityKey == "mbid:artist-mbid")

        await flags.setFailing(false)
        await runtime.charts?.refresh()
        #expect(await lastFMUserInfoRequestCount(transport) == infoAfterFailedTotal + 1)
        #expect(await lastFMTopRequestCount(transport) == topAfterAutomatic + 1)
        #expect(state.chartState.totals == .account(ChartAccountTotal(
            value: 9_999,
            serviceName: "Last.fm",
            savedAt: clock.now,
        )))
        #expect(state.chartState.totalFailure == nil)
        #expect(state.chartState.phase == .ready)
        #expect(
            state.chartState.snapshot?.items.first?.identityKey == "mbid:artist-mbid",
            "manual recovery keeps the provider list identity",
        )
        #expect(state.chartState.snapshot?.localTotal == nil)
    }

    // swiftlint:disable:next function_body_length
    @Test func listenBrainzChartMatrixKeepsOrderAndCapsEveryEntityAndPeriod() async throws {
        let database = try TemporaryDatabase()
        let now = chartDate(2026, 10, 31, 12)
        let clock = FakeClock(now)
        let from = chartDate(2026, 10, 20)
        let periodEnd = chartDate(2026, 10, 27)
        let updated = chartDate(2026, 10, 28, 6)
        let transport = ChartHTTPTransport { request in
            let path = chartListenBrainzPath(request)
            if path.hasSuffix("validate-token") {
                return listenBrainzValidResponse()
            }
            if path.hasSuffix("listen-count") {
                return listenBrainzCountResponse(9_876)
            }
            let type: ChartType = path.contains("/artists")
                ? .artists
                : path.contains("/releases") ? .albums : .tracks
            // swiftlint:disable:next large_tuple
            let rows: [(String, String, Int, String)] = (0 ..< 51).map { index in
                (
                    "Entity \(index + 1)",
                    type == .artists ? "" : "Artist \(index + 1)",
                    index == 1 ? 999 : 100 - index,
                    index == 1 ? "" : "mbid-\(index + 1)",
                )
            }
            return listenBrainzStatsResponse(
                type: type,
                rows: rows,
                from: from,
                end: periodEnd,
                lastUpdated: updated,
            )
        }
        let state = TracklogAppState()
        let calendarBox = ChartCalendarBox(chartCalendar(utc))
        let runtime = makeChartRuntime(
            database: database,
            clock: clock,
            transport: transport,
            state: state,
            selection: chartSelection(source: .service, period: .week, now: now, calendar: calendarBox.calendar),
            calendarBox: calendarBox,
        )
        await runtime.start()
        _ = try await runtime.link(kind: .listenBrainz, credential: "token")
        await runtime.charts?.show()

        for period in [ChartPeriod.week, .month, .year, .allTime] {
            await runtime.charts?.selectPeriod(period)
            for type in ChartType.allCases {
                await runtime.charts?.selectType(type)
                let snapshot = try #require(state.chartState.snapshot)
                #expect(snapshot.type == type)
                #expect(snapshot.period == period)
                #expect(snapshot.items.count == 50, "\(type) \(period) keeps the first 50")
                #expect(snapshot.items.map(\.rank) == Array(1 ... 50))
                #expect(snapshot.items.first?.title == "Entity 1")
                #expect(snapshot.items.first?.count == 100)
                #expect(snapshot.items.dropFirst().first?.title == "Entity 2")
                #expect(snapshot.items.dropFirst().first?.count == 999, "provider order is not re-sorted")
                #expect(snapshot.items.last?.title == "Entity 50")
                #expect(!snapshot.items.contains { $0.title == "Entity 51" })
                let missingID = try #require(snapshot.items.dropFirst().first)
                #expect(missingID.providerID == nil)
                #expect(missingID.identityKey.hasPrefix("fallback:listenbrainz:\(type.rawValue):"))
            }
        }

        let stats = await transport.recordedRequests.filter {
            chartListenBrainzPath($0).contains("/stats/user/")
        }
        #expect(stats.count == 12, "every entity and every accepted period is requested once")
        #expect(stats.allSatisfy { $0.headers["Authorization"] == "Token token" })
        #expect(stats.allSatisfy { chartQueryValue("count", in: $0) == "50" })
        #expect(stats.allSatisfy { chartQueryValue("offset", in: $0) == "0" })
        #expect(
            Set(stats.compactMap { chartQueryValue("range", in: $0) })
                == Set(["week", "month", "year", "all_time"]),
        )
        for range in ["week", "month", "year", "all_time"] {
            #expect(stats.filter { chartQueryValue("range", in: $0) == range }.count == 3)
        }
        #expect(stats.filter { chartListenBrainzPath($0).contains("/artists") }.count == 4)
        #expect(stats.filter { chartListenBrainzPath($0).contains("/releases") }.count == 4)
        #expect(stats.filter { chartListenBrainzPath($0).contains("/recordings") }.count == 4)
        #expect(await listenBrainzCountRequestCount(transport) == 1)
    }

    @Test func listenBrainzFetchesTheAccountTotalOnlyForAllTime() async throws {
        let database = try TemporaryDatabase()
        let now = chartDate(2026, 10, 31, 12)
        let clock = FakeClock(now)
        let transport = listenBrainzTransport(flags: ChartFlags())
        let state = TracklogAppState()
        let calendarBox = ChartCalendarBox(chartCalendar(utc))
        let runtime = makeChartRuntime(
            database: database,
            clock: clock,
            transport: transport,
            state: state,
            selection: chartSelection(source: .service, period: .week, now: now, calendar: calendarBox.calendar),
            calendarBox: calendarBox,
        )
        let store = try SQLiteListenStore(url: database.url)
        await runtime.start()
        _ = try await runtime.link(kind: .listenBrainz, credential: "token")
        await runtime.charts?.show()
        #expect(state.chartState.totals == .unavailable(.rangeTotals))
        #expect(await listenBrainzCountRequestCount(transport) == 0)

        for period in [ChartPeriod.month, .year] {
            await runtime.charts?.selectPeriod(period)
            #expect(state.chartState.totals == .unavailable(.rangeTotals))
            #expect(await listenBrainzCountRequestCount(transport) == 0)
        }
        #expect(try await store.chartCacheCount() == 3, "three ranked lists and no account total")

        await runtime.charts?.selectPeriod(.allTime)
        #expect(state.chartState.totals == .account(ChartAccountTotal(
            value: 500,
            serviceName: "ListenBrainz",
            savedAt: now,
        )))
        #expect(await listenBrainzCountRequestCount(transport) == 1)
        #expect(
            try await store.chartCacheCount() == 5,
            "four ranked lists and one separately keyed account total",
        )

        clock.advance(to: now.addingTimeInterval(ChartFreshness.interval))
        runtime.charts?.hide()
        await runtime.charts?.show()
        #expect(await listenBrainzCountRequestCount(transport) == 2)
        #expect(state.chartState.totals == .account(ChartAccountTotal(
            value: 500,
            serviceName: "ListenBrainz",
            savedAt: clock.now,
        )))
    }

    @Test func listenBrainzCopyMeasuresDataAgeFromTheReturnedEnd() {
        let now = chartDate(2026, 11, 8)
        let end = chartDate(2026, 10, 19)
        let range = ChartReturnedRange(
            start: chartDate(2026, 10, 12),
            end: end,
            lastUpdated: end,
        )
        let label = ChartCopy.returnedRangeLabel(
            range,
            period: .week,
            serviceKind: .listenBrainz,
            now: now,
            calendar: chartCalendar(utc),
        )
        #expect(label.contains("data ends 20 d ago"))
        #expect(label.contains("statistics updated"))
        #expect(!label.contains("lag"))
        #expect(label.contains("Oct 12, 2026"))
        #expect(label.contains("Oct 18, 2026"), "the exclusive end is shown as the last included day")
    }

    @Test func listenBrainzDataAgeUsesTheUnadjustedReturnedEnd() {
        let now = chartDate(2026, 11, 8)
        let end = now.addingTimeInterval(-5 * 86_400 + 0.5)
        let range = ChartReturnedRange(start: chartDate(2026, 10, 1), end: end, lastUpdated: end)
        let label = ChartCopy.returnedRangeLabel(
            range,
            period: .week,
            serviceKind: .listenBrainz,
            now: now,
            calendar: chartCalendar(utc),
        )
        #expect(
            label.contains("data ends 4 d ago"),
            "the last included day is adjusted for display, but the age uses the returned end: \(label)",
        )
    }

    @Test func listenBrainzSpanIsAUTCWeekInEveryMacZone() throws {
        let range = ChartReturnedRange(
            start: chartDate(2026, 10, 12),
            end: chartDate(2026, 10, 19),
            lastUpdated: chartDate(2026, 10, 24, 4, 50),
        )
        let now = chartDate(2026, 10, 30, 12)
        for zone in ["Pacific/Auckland", "America/Los_Angeles"] {
            let calendar = try chartCalendar(#require(TimeZone(identifier: zone)))
            let label = ChartCopy.returnedRangeLabel(
                range,
                period: .week,
                serviceKind: .listenBrainz,
                now: now,
                calendar: calendar,
            )
            #expect(label.contains("Oct 12, 2026"), "\(zone): \(label)")
            #expect(label.contains("Oct 18, 2026"), "\(zone): \(label)")
            #expect(!label.contains("Oct 19, 2026"), "\(zone): \(label)")
        }
        let auckland = try ChartCopy.returnedRangeLabel(
            range,
            period: .week,
            serviceKind: .listenBrainz,
            now: now,
            calendar: chartCalendar(#require(TimeZone(identifier: "Pacific/Auckland"))),
        )
        #expect(auckland.contains("Oct 24, 2026"), "the updated instant stays local: \(auckland)")
        let losAngeles = try ChartCopy.returnedRangeLabel(
            range,
            period: .week,
            serviceKind: .listenBrainz,
            now: now,
            calendar: chartCalendar(#require(TimeZone(identifier: "America/Los_Angeles"))),
        )
        #expect(losAngeles.contains("Oct 23, 2026"), "the updated instant stays local: \(losAngeles)")
    }

    @Test func listenBrainzAllTimeSpanShowsTheReturnedDatesWithoutShiftingThem() {
        let range = ChartReturnedRange(
            start: chartDate(2002, 1, 1),
            end: chartDate(2026, 9, 27, 0, 13),
            lastUpdated: chartDate(2026, 9, 27, 12, 11),
        )
        let label = ChartCopy.returnedRangeLabel(
            range,
            period: .allTime,
            serviceKind: .listenBrainz,
            now: chartDate(2026, 11, 4),
            calendar: chartCalendar(utc),
        )
        #expect(label.contains("Jan 1, 2002"))
        #expect(label.contains("Sep 27, 2026"), "the latest returned listen is not shifted to the previous day")
        #expect(!label.contains("Sep 26, 2026"))
        #expect(label.contains("data ends"))
    }

    @Test func listenBrainzMissingBoundsAreNotInvented() async throws {
        let database = try TemporaryDatabase()
        let now = chartDate(2026, 10, 31, 12)
        let clock = FakeClock(now)
        let transport = ChartHTTPTransport { request in
            let path = chartListenBrainzPath(request)
            if path.hasSuffix("validate-token") {
                return listenBrainzValidResponse()
            }
            return listenBrainzStatsResponse(
                type: .artists,
                rows: [("Blondie", "", 42, "artist-mbid")],
                from: chartDate(2026, 10, 20),
                end: chartDate(2026, 10, 27),
                lastUpdated: chartDate(2026, 10, 28, 6),
                includeBounds: false,
            )
        }
        let state = TracklogAppState()
        let calendarBox = ChartCalendarBox(chartCalendar(utc))
        let runtime = makeChartRuntime(
            database: database,
            clock: clock,
            transport: transport,
            state: state,
            selection: chartSelection(source: .service, period: .week, now: now, calendar: calendarBox.calendar),
            calendarBox: calendarBox,
        )
        await runtime.start()
        _ = try await runtime.link(kind: .listenBrainz, credential: "token")
        await runtime.charts?.show()

        #expect(state.chartState.phase == .ready)
        #expect(state.chartState.snapshot?.items.first?.title == "Blondie")
        #expect(
            state.chartState.snapshot?.returnedRange == nil,
            "a response without from_ts/to_ts must not invent a span",
        )
    }

    @Test func listenBrainzNotReadyAccountTotalKeepsRankedRows() async throws {
        let database = try TemporaryDatabase()
        let now = chartDate(2026, 10, 31, 12)
        let clock = FakeClock(now)
        let flags = ChartFlags()
        await flags.setNotReadyTotal(true)
        let transport = listenBrainzTransport(flags: flags)
        let state = TracklogAppState()
        let calendarBox = ChartCalendarBox(chartCalendar(utc))
        let runtime = makeChartRuntime(
            database: database,
            clock: clock,
            transport: transport,
            state: state,
            selection: chartSelection(source: .service, period: .allTime, now: now, calendar: calendarBox.calendar),
            calendarBox: calendarBox,
        )
        await runtime.start()
        _ = try await runtime.link(kind: .listenBrainz, credential: "token")
        await runtime.charts?.show()

        #expect(state.chartState.phase == .ready)
        #expect(state.chartState.snapshot?.items.first?.title == "Blondie")
        #expect(state.chartState.totals == .unavailable(.accountTotal(.notReady)))
        #expect(state.chartState.totalFailure == .notReady)

        await flags.setNotReadyTotal(false)
        await runtime.charts?.refresh()
        #expect(state.chartState.totals == .account(ChartAccountTotal(
            value: 500,
            serviceName: "ListenBrainz",
            savedAt: now,
        )))
        #expect(state.chartState.totalFailure == nil)
        #expect(state.chartState.snapshot?.items.first?.title == "Blondie")
    }

    // MARK: - Helpers

    private func listenBrainzCountRequestCount(_ transport: ChartHTTPTransport) async -> Int {
        await transport.recordedRequests.filter {
            chartListenBrainzPath($0).hasSuffix("listen-count")
        }.count
    }

    private func lastFMUserInfoRequestCount(_ transport: ChartHTTPTransport) async -> Int {
        await transport.recordedRequests.filter { chartMethod($0) == "user.getInfo" }.count
    }

    private func lastFMTopRequestCount(_ transport: ChartHTTPTransport) async -> Int {
        await transport.recordedRequests.filter(chartIsLastFMTopRequest).count
    }

    private struct ServiceRead {
        let state: TracklogAppState
        let runtime: CaptureRuntime
    }

    private func serviceRead(
        type: ChartType,
        handler: @escaping ChartHTTPTransport.Handler,
    ) async throws -> ServiceRead {
        let database = try TemporaryDatabase()
        let now = chartDate(2026, 10, 31, 12)
        let clock = FakeClock(now)
        let transport = ChartHTTPTransport(handler: handler)
        let state = TracklogAppState()
        let calendarBox = ChartCalendarBox(chartCalendar(utc))
        let runtime = makeChartRuntime(
            database: database,
            clock: clock,
            transport: transport,
            state: state,
            selection: chartSelection(
                source: .service,
                period: .week,
                type: type,
                now: now,
                calendar: calendarBox.calendar,
            ),
            calendarBox: calendarBox,
        )
        await runtime.start()
        _ = try await runtime.link(kind: .listenBrainz, credential: "token")
        await runtime.charts?.show()
        return ServiceRead(state: state, runtime: runtime)
    }
}
