// swiftlint:disable file_length function_body_length large_tuple type_body_length optional_data_string_conversion
import Foundation
import Testing
@testable import TracklogCore

@Suite("Chart service reads")
@MainActor
struct ChartServiceTests {
    private let utc = TimeZone(identifier: "UTC")!

    @Test func lastFMChartsUseRollingPeriodsAndProviderCounts() async throws {
        let database = try TemporaryDatabase()
        let now = chartDate(2026, 10, 31, 12)
        let clock = FakeClock(now)
        let flags = ChartFlags()
        let artists: [(String, String, Int, String)] = [
            ("Blondie", "", 42, "artist-mbid"),
            ("Missing MBID", "", 7, ""),
        ]
        let albums: [(String, String, Int, String)] = [
            ("Parallel Lines", "Blondie", 30, "album-mbid"),
        ]
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
        #expect(second.identityKey.hasPrefix("fallback:"))
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
        await runtime.charts?.selectPeriod(.allTime)
        #expect(state.chartState.periodDetail == "All time")
        #expect(state.chartState.totals == .account(ChartAccountTotal(
            value: 9_999,
            serviceName: "Last.fm",
            savedAt: now,
        )))
        #expect(await transport.recordedRequests.filter { chartMethod($0) == "user.getInfo" }.count == 2)
    }

    @Test func listenBrainzChartsUseCompletedPeriodsAndReturnedDates() async throws {
        let database = try TemporaryDatabase()
        let now = chartDate(2026, 10, 31, 12)
        let clock = FakeClock(now)
        let from = chartDate(2026, 10, 20)
        let periodEnd = chartDate(2026, 10, 27)
        let updated = chartDate(2026, 10, 28, 6)
        let transport = ChartHTTPTransport { request in
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
                    from: from,
                    end: periodEnd,
                    lastUpdated: updated,
                )
            }
            if chartListenBrainzPath(request).contains("/releases") {
                return listenBrainzStatsResponse(
                    type: .albums,
                    rows: [("Parallel Lines", "Blondie", 30, "release-mbid")],
                    from: from,
                    end: periodEnd,
                    lastUpdated: updated,
                )
            }
            if chartListenBrainzPath(request).contains("/recordings") {
                return listenBrainzStatsResponse(
                    type: .tracks,
                    rows: [("Heart of Glass", "Blondie", 20, "recording-mbid")],
                    from: from,
                    end: periodEnd,
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

        for (period, value) in [(ChartPeriod.month, "month"), (.year, "year"), (.allTime, "all_time")] {
            await runtime.charts?.selectPeriod(period)
            let request = try #require(
                await transport.recordedRequests.last { chartListenBrainzPath($0).contains("/stats/user/") },
            )
            #expect(chartQueryValue("range", in: request) == value)
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
        try await store.insert(chartListen(title: "Local", artist: "Artist", startedAt: now))
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

    // MARK: - Helpers

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

// swiftlint:enable file_length function_body_length large_tuple type_body_length optional_data_string_conversion
