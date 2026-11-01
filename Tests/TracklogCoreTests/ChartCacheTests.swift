// swiftlint:disable file_length function_body_length cyclomatic_complexity large_tuple type_body_length
import Foundation
import Testing
@testable import TracklogCore

@Suite("Chart cache and lifecycle")
@MainActor
struct ChartCacheTests {
    private let utc = TimeZone(identifier: "UTC")!

    @Test func cacheIsFreshForFifteenMinutesThenRefreshes() async throws {
        let database = try TemporaryDatabase()
        let now = chartDate(2026, 10, 31, 12)
        let clock = FakeClock(now)
        let flags = ChartFlags()
        let transport = listenBrainzTransport(flags: flags)
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
        let savedAt = try #require(state.chartState.snapshot?.savedAt)
        #expect(await chartStatsRequestCount(transport) == 1)

        runtime.charts?.hide()
        clock.advance(to: now.addingTimeInterval(5 * 60))
        await runtime.charts?.show()
        #expect(await chartStatsRequestCount(transport) == 1)
        #expect(state.chartState.snapshot?.savedAt == savedAt)
        #expect(state.chartState.snapshot?.items.first?.title == "Blondie")

        runtime.charts?.hide()
        clock.advance(to: now.addingTimeInterval(20 * 60))
        await runtime.charts?.show()
        #expect(await chartStatsRequestCount(transport) == 2)
        #expect(state.chartState.snapshot?.savedAt == clock.now)
        #expect(try await store.chartCacheCount() == 1)
    }

    @Test func aFailedRefreshKeepsRowsAndTheirOriginalAge() async throws {
        let database = try TemporaryDatabase()
        let now = chartDate(2026, 10, 31, 12)
        let clock = FakeClock(now)
        let flags = ChartFlags()
        let transport = listenBrainzTransport(flags: flags)
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
        let original = try #require(state.chartState.snapshot)
        let originalSavedAt = original.savedAt

        clock.advance(to: now.addingTimeInterval(20 * 60))
        await flags.setFailing(true)
        runtime.charts?.hide()
        await runtime.charts?.show()

        #expect(state.chartState.snapshot == original)
        #expect(state.chartState.snapshot?.savedAt == originalSavedAt)
        #expect(state.chartState.refreshFailure == .offline)
        #expect(state.chartState.phase == .ready)
        #expect(state.chartState.isRefreshing == false)
    }

    @Test func aFailedRefreshWithoutSavedRowsShowsTheFailure() async throws {
        let database = try TemporaryDatabase()
        let now = chartDate(2026, 10, 31, 12)
        let clock = FakeClock(now)
        let flags = ChartFlags()
        await flags.setFailing(true)
        let transport = listenBrainzTransport(flags: flags)
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
        #expect(state.chartState.phase == .failed(.offline))
        #expect(state.chartState.snapshot == nil)
        #expect(state.chartState.refreshFailure == nil)
    }

    @Test func notReadyWithSavedRowsKeepsThemAndNotReadyWithoutDataIsItsOwnState() async throws {
        let database = try TemporaryDatabase()
        let now = chartDate(2026, 10, 31, 12)
        let clock = FakeClock(now)
        let flags = ChartFlags()
        let transport = listenBrainzTransport(flags: flags)
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
        let original = try #require(state.chartState.snapshot)

        clock.advance(to: now.addingTimeInterval(20 * 60))
        await flags.setNotReady(true)
        runtime.charts?.hide()
        await runtime.charts?.show()
        #expect(state.chartState.snapshot == original)
        #expect(state.chartState.refreshFailure == .notReady)
        #expect(state.chartState.phase == .ready)

        let emptyDatabase = try TemporaryDatabase()
        let emptyFlags = ChartFlags()
        await emptyFlags.setNotReady(true)
        let emptyState = TracklogAppState()
        let emptyRuntime = makeChartRuntime(
            database: emptyDatabase,
            clock: FakeClock(now),
            transport: listenBrainzTransport(flags: emptyFlags),
            state: emptyState,
            selection: chartSelection(source: .service, period: .week, now: now, calendar: calendarBox.calendar),
            calendarBox: ChartCalendarBox(chartCalendar(utc)),
        )
        await emptyRuntime.start()
        _ = try await emptyRuntime.link(kind: .listenBrainz, credential: "token")
        await emptyRuntime.charts?.show()
        #expect(emptyState.chartState.phase == .notReady)
        #expect(emptyState.chartState.snapshot == nil)
    }

    @Test func repeatedRefreshesCoalesce() async throws {
        let database = try TemporaryDatabase()
        let now = chartDate(2026, 10, 31, 12)
        let clock = FakeClock(now)
        let flags = ChartFlags()
        let gate = ChartHoldGate()
        let transport = listenBrainzTransport(flags: flags, gate: gate)
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
        #expect(await chartStatsRequestCount(transport) == 1)

        await gate.startHolding()
        let first = Task { await runtime.charts?.refresh() }
        await gate.waitUntilEntered(1)
        let second = Task { await runtime.charts?.refresh() }
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        await gate.release()
        await first.value
        await second.value
        #expect(await chartStatsRequestCount(transport) == 2, "two refreshes share one request")
    }

    @Test func aLateResponseAfterSelectionChangeCannotBecomeCurrentOrBeCached() async throws {
        let database = try TemporaryDatabase()
        let now = chartDate(2026, 10, 31, 12)
        let clock = FakeClock(now)
        let flags = ChartFlags()
        let gate = ChartHoldGate()
        let transport = listenBrainzTransport(flags: flags, gate: gate)
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

        await gate.startHolding()
        let show = Task { await runtime.charts?.show() }
        await gate.waitUntilEntered(1)
        let switchType = Task { await runtime.charts?.selectType(.albums) }
        await gate.waitUntilEntered(2)
        #expect(state.chartState.snapshot == nil, "the old selection's rows are gone while the new one loads")
        await gate.release()
        await show.value
        await switchType.value

        #expect(state.chartState.snapshot?.type == .albums)
        #expect(state.chartState.snapshot?.items.first?.title == "Parallel Lines")
        #expect(try await store.chartCacheCount() == 1, "the obsolete artists response was never stored")
    }

    @Test func cachedRowsAreScopedByAccountAndSelection() async throws {
        let database = try TemporaryDatabase()
        let now = chartDate(2026, 10, 31, 12)
        let clock = FakeClock(now)
        let flags = ChartFlags()
        let alpha = try #require(ServiceEndpoint(normalizing: "https://lb-alpha.example"))
        let beta = try #require(ServiceEndpoint(normalizing: "https://lb-beta.example"))
        let transport = ChartHTTPTransport { request in
            let path = chartListenBrainzPath(request)
            if path.hasSuffix("validate-token") {
                let isAlpha = request.url.host?.contains("alpha") == true
                return listenBrainzValidResponse(user: isAlpha ? "alpha" : "beta")
            }
            if path.contains("/stats/user/") {
                if await flags.isFailing() {
                    throw URLError(.notConnectedToInternet)
                }
                let isAlpha = path.contains("/user/alpha/")
                let title = isAlpha ? "Alpha Artist" : "Beta Artist"
                let type: ChartType = path.contains("/artists")
                    ? .artists
                    : path.contains("/releases") ? .albums : .tracks
                return listenBrainzStatsResponse(
                    type: type,
                    rows: [(title, "", isAlpha ? 11 : 22, "")],
                    from: chartDate(2026, 10, 20),
                    end: chartDate(2026, 10, 27),
                    lastUpdated: chartDate(2026, 10, 28, 6),
                )
            }
            if path.contains("listen-count") {
                return listenBrainzCountResponse(path.contains("/user/alpha/") ? 111 : 222)
            }
            return HTTPResponse(statusCode: 404, body: Data())
        }
        let state = TracklogAppState()
        let calendarBox = ChartCalendarBox(chartCalendar(utc))
        let store = try SQLiteListenStore(url: database.url)
        let credentials = MemoryCredentialStore()
        let alphaConnection = try await store.save(Connection(
            kind: .listenBrainz,
            endpoint: alpha,
            identity: "alpha",
            createdAt: now,
            lastUsedAt: now,
        ))
        let betaConnection = try await store.save(Connection(
            kind: .listenBrainz,
            endpoint: beta,
            identity: "beta",
            createdAt: now.addingTimeInterval(1),
            lastUsedAt: now.addingTimeInterval(1),
        ))
        let alphaID = try #require(alphaConnection.id)
        let betaID = try #require(betaConnection.id)
        try await credentials.saveCredential("alpha-token", forConnection: alphaID)
        try await credentials.saveCredential("beta-token", forConnection: betaID)
        try await store.setCurrentConnectionID(alphaID)

        let runtime = makeChartRuntime(
            database: database,
            clock: clock,
            transport: transport,
            state: state,
            selection: chartSelection(source: .service, period: .week, now: now, calendar: calendarBox.calendar),
            calendarBox: calendarBox,
            credentials: credentials,
        )
        await runtime.start()
        await runtime.charts?.show()
        #expect(state.chartState.snapshot?.items.first?.title == "Alpha Artist")

        try await runtime.setCurrentConnection(betaID)
        await runtime.charts?.show()
        #expect(state.chartState.snapshot?.items.first?.title == "Beta Artist")

        await flags.setFailing(true)
        await runtime.charts?.selectType(.albums)
        #expect(state.chartState.phase == .failed(.offline))
        #expect(state.chartState.snapshot == nil)

        await runtime.charts?.selectType(.artists)
        #expect(state.chartState.snapshot?.items.first?.title == "Beta Artist")
        #expect(state.chartState.snapshot?.items.first?.title != "Alpha Artist")

        try await runtime.setCurrentConnection(alphaID)
        await runtime.charts?.show()
        #expect(state.chartState.snapshot?.items.first?.title == "Alpha Artist")

        try await runtime.setCurrentConnection(betaID)
        await runtime.charts?.selectPeriod(.month)
        #expect(state.chartState.snapshot == nil)
        #expect(state.chartState.phase == .failed(.offline))
        #expect(try await store.chartCacheCount() == 2, "only the two successfully read week lists are cached")
    }

    @Test func unlinkEvictsRemoteCacheAndRelinkCannotShowIt() async throws {
        let database = try TemporaryDatabase()
        let now = chartDate(2026, 10, 31, 12)
        let clock = FakeClock(now)
        let flags = ChartFlags()
        let transport = listenBrainzTransport(flags: flags)
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
        let connection = try await runtime.link(kind: .listenBrainz, credential: "token")
        await runtime.charts?.show()
        #expect(try await store.chartCacheCount() == 1)

        _ = try await runtime.unlinkConnection(id: connection.id ?? -1)
        #expect(try await store.chartCacheCount() == 0, "unlink evicts the remote rows in its transaction")

        await flags.setFailing(true)
        _ = try await runtime.link(kind: .listenBrainz, credential: "token")
        await runtime.charts?.show()
        #expect(state.chartState.snapshot == nil)
        #expect(state.chartState.phase == .failed(.offline))
    }

    @Test func identityReplacementEvictsTheOldAccountAndCannotShowIt() async throws {
        let database = try TemporaryDatabase()
        let now = chartDate(2026, 10, 31, 12)
        let clock = FakeClock(now)
        let flags = ChartFlags()
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
        let store = try SQLiteListenStore(url: database.url)
        await runtime.start()
        let connection = try await runtime.link(kind: .listenBrainz, credential: "token")
        await runtime.charts?.show()
        #expect(try await store.chartCacheCount() == 2, "list and all-time account total")

        await flags.setFailing(true)
        _ = try await runtime.reauthenticate(
            id: connection.id ?? -1,
            credential: "new-token",
            identity: ServiceIdentity(name: "other-listener"),
            confirmReplacement: { _, _, _ in true },
        )
        #expect(try await store.chartCacheCount() == 0, "the replaced identity's rows are gone")

        await runtime.charts?.show()
        #expect(state.chartState.snapshot == nil)
        #expect(state.chartState.phase == .failed(.offline))
        #expect(state.currentConnection?.identity == "other-listener")
    }

    @Test func deactivateStopsLateWorkAndReactivationLoadsAgain() async throws {
        let database = try TemporaryDatabase()
        let now = chartDate(2026, 10, 31, 12)
        let clock = FakeClock(now)
        let flags = ChartFlags()
        let gate = ChartHoldGate()
        let transport = listenBrainzTransport(flags: flags, gate: gate)
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
        await gate.startHolding()
        let show = Task { await runtime.charts?.show() }
        await gate.waitUntilEntered(1)
        runtime.stop()
        #expect(runtime.charts?.isActive == false)
        await gate.release()
        await show.value
        #expect(try await store.chartCacheCount() == 0)
        #expect(state.chartState.snapshot == nil)

        await runtime.start()
        await runtime.charts?.show()
        #expect(state.chartState.snapshot?.items.first?.title == "Blondie")
    }

    @Test func allTimeTotalsKeepTheirOwnAgeWhenOnlyTheTotalFails() async throws {
        let database = try TemporaryDatabase()
        let now = chartDate(2026, 10, 31, 12)
        let clock = FakeClock(now)
        let flags = ChartFlags()
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
        let store = try SQLiteListenStore(url: database.url)
        await runtime.start()
        let connection = try await runtime.link(kind: .listenBrainz, credential: "token")
        await runtime.charts?.show()
        let listSavedAt = try #require(state.chartState.snapshot?.savedAt)
        #expect(state.chartState.totals == .account(ChartAccountTotal(
            value: 500,
            serviceName: "ListenBrainz",
            savedAt: now,
        )))
        let statsBefore = await chartStatsRequestCount(transport)

        let oldTotalDate = now.addingTimeInterval(-20 * 60)
        let oldTotal = ChartAccountTotal(value: 4321, serviceName: "ListenBrainz", savedAt: oldTotalDate)
        let totalKey = ChartCacheKey(
            kind: .total,
            source: .service,
            serviceKind: .listenBrainz,
            endpoint: connection.endpoint.description,
            account: connection.identity,
            chartType: nil,
            period: .allTime,
        )
        try await store.saveChartCache(
            ChartCacheEntry(savedAt: oldTotalDate, payload: JSONEncoder().encode(oldTotal)),
            for: totalKey,
        )
        await flags.setFailingTotal(true)
        runtime.charts?.hide()
        runtime.stop()
        await runtime.start()
        await runtime.charts?.show()

        #expect(state.chartState.snapshot?.savedAt == listSavedAt)
        #expect(state.chartState.totals == .account(oldTotal))
        #expect(state.chartState.totalFailure == .offline)
        #expect(await chartStatsRequestCount(transport) == statsBefore, "the fresh list was not refetched")
    }

    @Test func chartWorkDoesNotBlockCaptureDeliveryOrHistory() async throws {
        let database = try TemporaryDatabase()
        let now = chartDate(2026, 10, 31, 12)
        let clock = FakeClock(now)
        let flags = ChartFlags()
        let gate = ChartHoldGate()
        let transport = listenBrainzTransport(flags: flags, gate: gate)
        let state = TracklogAppState()
        let calendarBox = ChartCalendarBox(chartCalendar(utc))
        let runtime = makeChartRuntime(
            database: database,
            clock: clock,
            transport: transport,
            state: state,
            selection: chartSelection(source: .service, period: .allTime, now: now, calendar: calendarBox.calendar),
            calendarBox: calendarBox,
            scrobblingEnabled: true,
        )
        let store = try SQLiteListenStore(url: database.url)
        await runtime.start()
        _ = try await runtime.link(kind: .listenBrainz, credential: "token")

        await gate.startHolding()
        let chartTask = Task { await runtime.charts?.show() }
        await gate.waitUntilEntered(1)
        #expect(state.chartState.phase == .loading)

        let track = Track(
            title: "Chart Continuity",
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
        #expect(state.nowPlaying?.track.title == "Chart Continuity")
        let listen = try #require(state.listens.first { $0.processed.title == "Chart Continuity" })
        #expect(state.historyCount == 1)
        // The now-playing send just used this connection's one-second spacing
        // slot. The fake clock has to cross it before the queued scrobble.
        clock.advance(to: clock.now.addingTimeInterval(2))
        let delivered = await chartWaitForDelivery(store, listenID: listen.id ?? -1)
        #expect(
            delivered?.state == .delivered,
            "the outbox did not progress while charts loaded",
        )
        #expect(state.chartState.phase == .loading, "capture did not wait for charts")

        await gate.release()
        await chartTask.value
        #expect(state.chartState.snapshot?.items.first?.title == "Blondie")
        #expect(state.listens.contains { $0.processed.title == "Chart Continuity" })
    }

    @Test func unlinkEvictionFailureKeepsTheConnectionAndItsCache() async throws {
        let database = try TemporaryDatabase()
        let now = chartDate(2026, 10, 31, 12)
        let clock = FakeClock(now)
        let flags = ChartFlags()
        let transport = listenBrainzTransport(flags: flags)
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
        let connection = try await runtime.link(kind: .listenBrainz, credential: "token")
        await runtime.charts?.show()
        #expect(try await store.chartCacheCount() == 1)

        try database.execute(
            """
            CREATE TRIGGER chart_cache_delete_guard
            BEFORE DELETE ON chart_cache
            BEGIN
                SELECT RAISE(ABORT, 'blocked chart cache delete');
            END;
            """,
        )
        do {
            _ = try await runtime.unlinkConnection(id: connection.id ?? -1)
            Issue.record("Unlink succeeded although its cache eviction failed")
        } catch {
            // Expected: the transaction rolled back.
        }
        #expect(state.connections.contains { $0.id == connection.id })
        #expect(try await store.chartCacheCount() == 1, "the old account's rows did not vanish behind a live connection")

        try database.execute("DROP TRIGGER chart_cache_delete_guard")
        _ = try await runtime.unlinkConnection(id: connection.id ?? -1)
        #expect(try await store.chartCacheCount() == 0)
    }

    @Test func restartOfflineRestoresTheMatchingSavedChartAndItsRealAge() async throws {
        let database = try TemporaryDatabase()
        let now = chartDate(2026, 10, 31, 12)
        let clock = FakeClock(now)
        let credentials = MemoryCredentialStore()
        let selection = chartSelection(
            source: .service,
            period: .week,
            now: now,
            calendar: chartCalendar(utc),
        )
        let flags = ChartFlags()
        let transport = listenBrainzTransport(flags: flags)
        let calendarBox = ChartCalendarBox(chartCalendar(utc))
        let state = TracklogAppState()
        let runtime = makeChartRuntime(
            database: database,
            clock: clock,
            transport: transport,
            state: state,
            selection: selection,
            calendarBox: calendarBox,
            credentials: credentials,
        )
        await runtime.start()
        _ = try await runtime.link(kind: .listenBrainz, credential: "token")
        await runtime.charts?.show()
        let savedAt = try #require(state.chartState.snapshot?.savedAt)
        runtime.stop()

        await flags.setFailing(true)
        clock.advance(to: now.addingTimeInterval(20 * 60))
        let offlineState = TracklogAppState()
        let offlineRuntime = makeChartRuntime(
            database: database,
            clock: clock,
            transport: transport,
            state: offlineState,
            selection: selection,
            calendarBox: ChartCalendarBox(chartCalendar(utc)),
            credentials: credentials,
        )
        await offlineRuntime.start()
        await offlineRuntime.charts?.show()
        #expect(offlineState.chartState.snapshot?.savedAt == savedAt)
        #expect(offlineState.chartState.snapshot?.items.first?.title == "Blondie")
        #expect(offlineState.chartState.refreshFailure == .offline)
    }

    @Test func anAuthFailureShowsNeedsSignInWithoutHidingSavedRows() async throws {
        let database = try TemporaryDatabase()
        let now = chartDate(2026, 10, 31, 12)
        let clock = FakeClock(now)
        let flags = ChartFlags()
        let transport = ChartHTTPTransport { request in
            let path = chartListenBrainzPath(request)
            if path.hasSuffix("validate-token") {
                return listenBrainzValidResponse()
            }
            if path.contains("/stats/user/") {
                if await flags.isFailing() {
                    return HTTPResponse(statusCode: 401, body: Data())
                }
                return listenBrainzStatsResponse(
                    type: .artists,
                    rows: [("Blondie", "", 42, "artist-mbid")],
                    from: chartDate(2026, 10, 20),
                    end: chartDate(2026, 10, 27),
                    lastUpdated: chartDate(2026, 10, 28, 6),
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
        _ = try await runtime.link(kind: .listenBrainz, credential: "token")
        await runtime.charts?.show()
        let original = try #require(state.chartState.snapshot)

        clock.advance(to: now.addingTimeInterval(20 * 60))
        await flags.setFailing(true)
        runtime.charts?.hide()
        await runtime.charts?.show()
        #expect(state.chartState.snapshot == original)
        #expect(state.chartState.refreshFailure == .needsSignIn)
    }

    @Test func aLocalReadFailureIsNotReportedAsAServiceFailure() async throws {
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
            selection: chartSelection(source: .local, period: .week, now: now, calendar: calendarBox.calendar),
            calendarBox: calendarBox,
        )
        await runtime.start()
        if let store = runtime.store as? SQLiteListenStore {
            await store.close()
        }
        await runtime.charts?.show()
        #expect(state.chartState.phase == .failed(.localRead))
        #expect(state.chartState.snapshot == nil)
    }

    @Test func aDelayedMissingCredentialCannotOverwriteANewSelection() async throws {
        let database = try TemporaryDatabase()
        let now = chartDate(2026, 10, 31, 12)
        let clock = FakeClock(now)
        let credentials = DelayedCredentialStore()
        let flags = ChartFlags()
        let transport = listenBrainzTransport(flags: flags)
        let state = TracklogAppState()
        let calendarBox = ChartCalendarBox(chartCalendar(utc))
        let runtime = makeChartRuntime(
            database: database,
            clock: clock,
            transport: transport,
            state: state,
            selection: chartSelection(source: .service, period: .week, now: now, calendar: calendarBox.calendar),
            calendarBox: calendarBox,
            credentials: credentials,
        )
        let store = try SQLiteListenStore(url: database.url)
        await runtime.start()
        _ = try await runtime.link(kind: .listenBrainz, credential: "token")

        await credentials.holdNextRead(.value(nil))
        let show = Task { await runtime.charts?.show() }
        await credentials.waitUntilRead()
        await runtime.charts?.selectSource(.local)
        await credentials.release()
        await show.value

        #expect(state.chartState.effectiveSource.isLocal)
        #expect(state.chartState.effectiveSource.serviceKind == nil)
        #expect(state.chartState.selection.source == .local)
        #expect(state.chartState.refreshFailure == nil)
        #expect(state.chartState.phase == .empty)
        #expect(state.chartState.snapshot?.localTotal == 0)
        #expect(try await store.chartCacheCount() == 1)
        let payloads = try await store.chartCachePayloads()
        #expect(!payloads.contains { data in
            String(data: data, encoding: .utf8)?.contains("list\u{1F}service") == true
        })
    }

    @Test func aDelayedCredentialErrorCannotPublishAfterDeactivation() async throws {
        let database = try TemporaryDatabase()
        let now = chartDate(2026, 10, 31, 12)
        let clock = FakeClock(now)
        let credentials = DelayedCredentialStore()
        let flags = ChartFlags()
        let transport = listenBrainzTransport(flags: flags)
        let state = TracklogAppState()
        let calendarBox = ChartCalendarBox(chartCalendar(utc))
        let runtime = makeChartRuntime(
            database: database,
            clock: clock,
            transport: transport,
            state: state,
            selection: chartSelection(source: .service, period: .week, now: now, calendar: calendarBox.calendar),
            calendarBox: calendarBox,
            credentials: credentials,
        )
        let store = try SQLiteListenStore(url: database.url)
        await runtime.start()
        _ = try await runtime.link(kind: .listenBrainz, credential: "token")

        await credentials.holdNextRead(.failure)
        let show = Task { await runtime.charts?.show() }
        await credentials.waitUntilRead()
        runtime.stop()
        await credentials.release()
        await show.value

        #expect(runtime.charts?.isActive == false)
        #expect(state.chartState.refreshFailure == nil)
        #expect(state.chartState.snapshot == nil)
        #expect(try await store.chartCacheCount() == 0)
    }

    @Test func localAggregationDoesNotBlockCaptureDeliveryOrHistory() async throws {
        let database = try TemporaryDatabase()
        let now = chartDate(2026, 10, 31, 12)
        let clock = FakeClock(now)
        let store = try SQLiteListenStore(url: database.url)
        for index in 0 ..< 200 {
            try await store.insert(chartListen(
                title: "Seed \(index)",
                artist: "Artist \(index % 20)",
                startedAt: now.addingTimeInterval(Double(index) - 1_000),
            ))
        }
        let flags = ChartFlags()
        let transport = listenBrainzTransport(flags: flags)
        let state = TracklogAppState()
        let calendarBox = ChartCalendarBox(chartCalendar(utc))
        let runtime = makeChartRuntime(
            database: database,
            clock: clock,
            transport: transport,
            state: state,
            selection: chartSelection(source: .local, period: .allTime, now: now, calendar: calendarBox.calendar),
            calendarBox: calendarBox,
            scrobblingEnabled: true,
            nowPlayingEnabled: false,
        )
        await runtime.start()
        _ = try await runtime.link(kind: .listenBrainz, credential: "token")

        let runtimeStore = try #require(runtime.store as? SQLiteListenStore)
        let gate = ChartHoldGate()
        await gate.startHolding()
        await runtimeStore.chartReader?.setRowObserver { row in
            if row == 64 {
                await gate.enter()
            }
        }

        let chartTask = Task { await runtime.charts?.show() }
        await gate.waitUntilEntered(1)
        #expect(state.chartState.phase == .loading)

        let track = Track(
            title: "During local chart",
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
        let listen = try #require(state.listens.first { $0.processed.title == "During local chart" })
        #expect(state.historyCount == 201)
        let delivered = await chartWaitForDelivery(store, listenID: listen.id ?? -1)
        #expect(delivered?.state == .delivered)
        #expect(state.chartState.phase == .loading, "the chart scan did not block capture")

        await gate.release()
        await chartTask.value
        #expect(state.chartState.snapshot?.localTotal == 200, "the scan keeps its consistent starting snapshot")
        #expect(state.historyCount == 201)
    }

    @Test func dismissingALocalScanCancelsItWithoutCaching() async throws {
        let database = try TemporaryDatabase()
        let now = chartDate(2026, 10, 31, 12)
        let clock = FakeClock(now)
        let store = try SQLiteListenStore(url: database.url)
        for index in 0 ..< 100 {
            try await store.insert(chartListen(
                title: "Seed \(index)",
                artist: "Artist \(index % 10)",
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
        let runtimeStore = try #require(runtime.store as? SQLiteListenStore)
        let gate = ChartHoldGate()
        await gate.startHolding()
        await runtimeStore.chartReader?.setRowObserver { row in
            if row == 64 {
                await gate.enter()
            }
        }

        let chartTask = Task { await runtime.charts?.show() }
        await gate.waitUntilEntered(1)
        runtime.charts?.hide()
        await gate.release()
        await chartTask.value
        #expect(state.chartState.snapshot == nil)
        #expect(try await store.chartCacheCount() == 0)
    }

    // MARK: - Fixtures

    private func listenBrainzTransport(
        flags: ChartFlags,
        gate: ChartHoldGate? = nil,
    ) -> ChartHTTPTransport {
        ChartHTTPTransport { request in
            let path = chartListenBrainzPath(request)
            if path.hasSuffix("validate-token") {
                return listenBrainzValidResponse()
            }
            if path.contains("submit-listens") {
                return chartJSONResponse(["status": "ok"])
            }
            if path.contains("/stats/user/") {
                if let gate {
                    await gate.enter()
                }
                if await flags.isNotReady() {
                    return HTTPResponse(statusCode: 204, body: Data())
                }
                if await flags.isFailing() {
                    throw URLError(.notConnectedToInternet)
                }
                let type: ChartType = path.contains("/artists")
                    ? .artists
                    : path.contains("/releases") ? .albums : .tracks
                let rows: [(String, String, Int, String)] = switch type {
                case .artists:
                    [("Blondie", "", 42, "artist-mbid"), ("Talking Heads", "", 30, "artist-mbid-2")]
                case .albums:
                    [("Parallel Lines", "Blondie", 42, "release-mbid")]
                case .tracks:
                    [("Heart of Glass", "Blondie", 42, "recording-mbid")]
                }
                return listenBrainzStatsResponse(
                    type: type,
                    rows: rows,
                    from: chartDate(2026, 10, 20),
                    end: chartDate(2026, 10, 27),
                    lastUpdated: chartDate(2026, 10, 28, 6),
                )
            }
            if path.contains("listen-count") {
                if await flags.isFailingTotal() {
                    throw URLError(.notConnectedToInternet)
                }
                return listenBrainzCountResponse(500)
            }
            return HTTPResponse(statusCode: 404, body: Data())
        }
    }

    private func chartStatsRequestCount(_ transport: ChartHTTPTransport) async -> Int {
        await transport.recordedRequests.filter {
            chartListenBrainzPath($0).contains("/stats/user/")
        }.count
    }
}

func chartWaitForDelivery(
    _ store: SQLiteListenStore,
    listenID: Int64,
    timeout: Duration = .seconds(5),
) async -> Delivery? {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        let deliveries = try? await store.deliveries(for: listenID)
        if let delivery = deliveries?.first, delivery.state == .delivered {
            return delivery
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return nil
}

// swiftlint:enable file_length function_body_length cyclomatic_complexity large_tuple type_body_length
