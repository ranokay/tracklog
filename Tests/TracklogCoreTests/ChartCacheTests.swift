// swiftlint:disable file_length function_body_length type_body_length
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
        #expect(await gate.waitUntilEntered(1), "the held transport is entered")
        let second = Task { await runtime.charts?.refresh() }
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        await gate.release()
        await first.value
        await second.value
        #expect(await chartStatsRequestCount(transport) == 2, "two refreshes share one request")
    }

    @Test func aManualRefreshDuringAFreshCacheReadForcesOneFetch() async throws {
        let database = try TemporaryDatabase()
        let now = chartDate(2026, 10, 31, 12)
        let clock = FakeClock(now)
        let store = try SQLiteListenStore(url: database.url)
        let connection = try await store.save(Connection(
            kind: .listenBrainz,
            endpoint: .listenBrainz,
            identity: "listener",
            createdAt: now,
        ))
        let connectionID = try #require(connection.id)
        let selection = chartSelection(
            source: .service,
            period: .week,
            now: now,
            calendar: chartCalendar(utc),
        )
        let key = ChartCacheKey(
            kind: .list,
            source: .service,
            serviceKind: .listenBrainz,
            endpoint: connection.endpoint.description,
            account: connection.identity,
            chartType: .artists,
            period: .week,
        )
        let cached = ChartSnapshot(
            scopeKey: key.rawKey,
            type: .artists,
            period: .week,
            items: [ChartItem(rank: 1, title: "Cached", count: 1, identityKey: "cached")],
            localTotal: nil,
            omittedCount: 0,
            returnedRange: nil,
            countUnit: .listens,
            savedAt: now.addingTimeInterval(-60),
        )
        let cachedPayload = try JSONEncoder().encode(cached)
        try await store.saveChartCache(
            ChartCacheEntry(savedAt: cached.savedAt, payload: cachedPayload),
            for: key,
        )
        let credentials = MemoryCredentialStore()
        try await credentials.saveCredential("token", forConnection: connectionID)
        let gate = ChartHoldGate()
        let transport = listenBrainzTransport(flags: ChartFlags(), gate: gate)
        let state = TracklogAppState()
        state.connections = [connection]
        state.currentConnectionID = connectionID
        let heldStore = HeldCacheChartStore(base: store)
        let model = ChartReadModel(
            state: state,
            store: heldStore,
            credentials: credentials,
            serviceClients: [ListenBrainzAdapter(transport: transport)],
            clock: clock,
            calendar: { chartCalendar(utc) },
            selection: selection,
        )
        model.activate()
        let joins = RefreshJoinCounter()
        model.setRefreshJoinObserver { joins.signal() }

        await heldStore.holdNextCacheRead()
        let showing = Task { await model.show() }
        #expect(await heldStore.waitUntilCacheRead(), "the initial cache read is entered")
        let firstRefresh = Task { await model.refresh() }
        let secondRefresh = Task { await model.refresh() }
        #expect(await joins.wait(for: 2), "both manual refreshes join the cache-only read")
        await gate.startHolding()
        await heldStore.releaseCacheRead()
        #expect(await gate.waitUntilEntered(1), "the refresh fetch reaches the held transport")
        #expect(state.chartState.snapshot?.items.first?.title == "Cached")
        await gate.release()
        await showing.value
        await firstRefresh.value
        await secondRefresh.value

        #expect(await chartStatsRequestCount(transport) == 1, "both manual refreshes share one forced fetch")
        #expect(state.chartState.snapshot?.items.first?.title == "Blondie")
        #expect(state.chartState.snapshot?.savedAt == clock.now)
    }

    @Test func aManualRefreshDuringAnInitialFetchCoalesces() async throws {
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
        let joins = RefreshJoinCounter()
        runtime.charts?.setRefreshJoinObserver { joins.signal() }

        await gate.startHolding()
        let showing = Task { await runtime.charts?.show() }
        #expect(await gate.waitUntilEntered(1), "the held transport is entered")
        let refreshing = Task { await runtime.charts?.refresh() }
        #expect(await joins.wait(for: 1), "the manual refresh joins the in-flight fetch")
        await gate.release()
        await showing.value
        await refreshing.value

        #expect(await chartStatsRequestCount(transport) == 1, "the manual refresh shares the fetch already underway")
    }

    @Test func aManualRefreshDuringATotalOnlyFetchStillRefreshesTheList() async throws {
        let database = try TemporaryDatabase()
        let now = chartDate(2026, 10, 31, 12)
        let clock = FakeClock(now)
        let store = try SQLiteListenStore(url: database.url)
        let connection = try await store.save(Connection(
            kind: .listenBrainz,
            endpoint: .listenBrainz,
            identity: "listener",
            createdAt: now,
        ))
        let connectionID = try #require(connection.id)
        let selection = chartSelection(
            source: .service,
            period: .allTime,
            now: now,
            calendar: chartCalendar(utc),
        )
        let key = ChartCacheKey(
            kind: .list,
            source: .service,
            serviceKind: .listenBrainz,
            endpoint: connection.endpoint.description,
            account: connection.identity,
            chartType: .artists,
            period: .allTime,
        )
        let cached = ChartSnapshot(
            scopeKey: key.rawKey,
            type: .artists,
            period: .allTime,
            items: [ChartItem(rank: 1, title: "Cached", count: 1, identityKey: "cached")],
            localTotal: nil,
            omittedCount: 0,
            returnedRange: nil,
            countUnit: .listens,
            savedAt: now.addingTimeInterval(-60),
        )
        let cachedPayload = try JSONEncoder().encode(cached)
        try await store.saveChartCache(
            ChartCacheEntry(savedAt: cached.savedAt, payload: cachedPayload),
            for: key,
        )
        let credentials = MemoryCredentialStore()
        try await credentials.saveCredential("token", forConnection: connectionID)
        let totalGate = ChartHoldGate()
        let transport = ChartHTTPTransport { request in
            let path = chartListenBrainzPath(request)
            if path.contains("/stats/user/") {
                return listenBrainzStatsResponse(
                    type: .artists,
                    rows: [("Blondie", "", 42, "artist-mbid")],
                    from: chartDate(2026, 10, 20),
                    end: chartDate(2026, 10, 27),
                    lastUpdated: chartDate(2026, 10, 28, 6),
                )
            }
            if path.contains("listen-count") {
                await totalGate.enter()
                return listenBrainzCountResponse(321)
            }
            return HTTPResponse(statusCode: 404, body: Data())
        }
        let state = TracklogAppState()
        state.connections = [connection]
        state.currentConnectionID = connectionID
        let model = ChartReadModel(
            state: state,
            store: store,
            credentials: credentials,
            serviceClients: [ListenBrainzAdapter(transport: transport)],
            clock: clock,
            calendar: { chartCalendar(utc) },
            selection: selection,
        )
        model.activate()
        let joins = RefreshJoinCounter()
        model.setRefreshJoinObserver { joins.signal() }

        await totalGate.startHolding()
        let showing = Task { await model.show() }
        #expect(await totalGate.waitUntilEntered(1), "the initial total fetch reaches the held transport")
        let refreshing = Task { await model.refresh() }
        #expect(await joins.wait(for: 1), "the manual refresh joins the held total read")
        await totalGate.release()
        await showing.value
        await refreshing.value

        let stats = await transport.recordedRequests.filter {
            chartListenBrainzPath($0).contains("/stats/user/")
        }
        #expect(stats.count == 1, "the manual refresh also refreshes the cached list")
        #expect(state.chartState.snapshot?.items.first?.title == "Blondie")
        #expect(state.chartState.snapshot?.savedAt == clock.now)
        #expect(state.chartState.totals == .account(ChartAccountTotal(
            value: 321,
            serviceName: "ListenBrainz",
            savedAt: clock.now,
        )))
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
        #expect(await gate.waitUntilEntered(1), "the held transport is entered")
        let switchType = Task { await runtime.charts?.selectType(.albums) }
        #expect(await gate.waitUntilEntered(2), "the held transport is entered")
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
        #expect(state.chartState.snapshot == nil, "the unlinked account's rows are not displayed")
        await turnMainActor()
        #expect(state.chartState.phase == .noConnection)

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
        #expect(await gate.waitUntilEntered(1), "the held transport is entered")
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
        #expect(await gate.waitUntilEntered(1), "the held transport is entered")
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

    @Test func switchingLocalTypeWhileAScanIsHeldUsesANewConnection() async throws {
        let database = try TemporaryDatabase()
        let now = chartDate(2026, 10, 31, 12)
        let clock = FakeClock(now)
        let store = try SQLiteListenStore(url: database.url)
        for index in 0 ..< 200 {
            try await store.insert(chartListen(
                title: "Seed \(index)",
                artist: "Artist \(index % 20)",
                album: "Album \(index % 10)",
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
        let counter = ChartHoldCounter()
        await gate.startHolding()
        await runtimeStore.chartReader?.setRowObserver { row in
            if row == 64, await counter.takeFirst() {
                await gate.enter()
            }
        }

        let first = Task { await runtime.charts?.show() }
        #expect(await gate.waitUntilEntered(1), "the held transport is entered")
        await runtime.charts?.selectType(.albums)
        #expect(state.chartState.snapshot?.type == .albums)
        #expect(state.chartState.phase == .ready)
        #expect(state.chartState.refreshFailure == nil)

        await gate.release()
        await first.value
        #expect(state.chartState.snapshot?.type == .albums)
        #expect(state.chartState.refreshFailure == nil)
        #expect(try await store.chartCacheCount() == 1)
    }

    @Test func hidingAndReopeningWhileALocalScanIsHeldUsesANewConnection() async throws {
        let database = try TemporaryDatabase()
        let now = chartDate(2026, 10, 31, 12)
        let clock = FakeClock(now)
        let store = try SQLiteListenStore(url: database.url)
        for index in 0 ..< 200 {
            try await store.insert(chartListen(
                title: "Seed \(index)",
                artist: "Artist \(index % 20)",
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
        let counter = ChartHoldCounter()
        await gate.startHolding()
        await runtimeStore.chartReader?.setRowObserver { row in
            if row == 64, await counter.takeFirst() {
                await gate.enter()
            }
        }

        let first = Task { await runtime.charts?.show() }
        #expect(await gate.waitUntilEntered(1), "the held transport is entered")
        runtime.charts?.hide()
        await runtime.charts?.show()
        #expect(state.chartState.snapshot?.localTotal == 200)
        #expect(state.chartState.refreshFailure == nil)

        await gate.release()
        await first.value
        #expect(state.chartState.snapshot?.localTotal == 200)
        #expect(state.chartState.refreshFailure == nil)
        #expect(try await store.chartCacheCount() == 1)
    }

    @Test func closingWhileALocalScanIsHeldDoesNotReuseTheClosedConnection() async throws {
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

        let show = Task { await runtime.charts?.show() }
        #expect(await gate.waitUntilEntered(1), "the held transport is entered")
        await runtimeStore.close()
        await gate.release()
        await show.value
        #expect(state.chartState.phase == .failed(.localRead))
        #expect(try await store.chartCacheCount() == 0)
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

    @Test func aDelayedBlankCredentialCannotOverwriteANewSelection() async throws {
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
        await runtime.start()
        _ = try await runtime.link(kind: .listenBrainz, credential: "token")

        await credentials.holdNextRead(.value("   "))
        let show = Task { await runtime.charts?.show() }
        await credentials.waitUntilRead()
        await runtime.charts?.selectSource(.local)
        await credentials.release()
        await show.value

        #expect(state.chartState.effectiveSource.isLocal)
        #expect(state.chartState.refreshFailure == nil)
        #expect(state.chartState.phase == .empty)
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
        #expect(await gate.waitUntilEntered(1), "the held transport is entered")
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
        #expect(await gate.waitUntilEntered(1), "the held transport is entered")
        runtime.charts?.hide()
        await gate.release()
        await chartTask.value
        #expect(state.chartState.snapshot == nil)
        #expect(try await store.chartCacheCount() == 0)
    }

    @Test func aVisibleFreshChartRefreshesAtFifteenMinutes() async throws {
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
        let savedAt = try #require(state.chartState.snapshot?.savedAt)
        #expect(await chartStatsRequestCount(transport) == 1)

        await gate.startHolding()
        clock.advance(to: now.addingTimeInterval(ChartFreshness.interval))
        #expect(await gate.waitUntilEntered(1), "the freshness wake reached the transport")
        #expect(state.chartState.isRefreshing)
        #expect(state.chartState.snapshot?.savedAt == savedAt, "saved rows stay visible while refreshing")
        await gate.release()
        #expect(await chartWaitForStatsRequestCount(transport, 2))
        #expect(await chartWaitUntil { state.chartState.isRefreshing == false })
        #expect(state.chartState.snapshot?.savedAt == clock.now)
        #expect(state.chartState.snapshot?.items.first?.title == "Blondie")
    }

    @Test func aFailedScheduledRefreshKeepsTheOriginalAgeAndDoesNotRetry() async throws {
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
        let original = try #require(state.chartState.snapshot)

        await gate.startHolding()
        await flags.setFailing(true)
        clock.advance(to: now.addingTimeInterval(ChartFreshness.interval))
        #expect(await gate.waitUntilEntered(1), "the scheduled refresh was attempted")
        await gate.release()
        #expect(await chartWaitUntil { state.chartState.refreshFailure == .offline })
        #expect(state.chartState.snapshot == original, "the failed refresh kept the saved rows and age")
        #expect(state.chartState.snapshot?.savedAt == original.savedAt)
        #expect(state.chartState.phase == .ready)

        let requestsAfterFailure = await chartStatsRequestCount(transport)
        clock.advance(to: now.addingTimeInterval(2 * ChartFreshness.interval))
        await turnMainActor(50)
        #expect(
            await chartStatsRequestCount(transport) == requestsAfterFailure,
            "a failed scheduled refresh is not retried by another clock advance",
        )
    }

    @Test func aNotReadyScheduledRefreshKeepsSavedRowsAndDoesNotPoll() async throws {
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
        let original = try #require(state.chartState.snapshot)

        await gate.startHolding()
        await flags.setNotReady(true)
        clock.advance(to: now.addingTimeInterval(ChartFreshness.interval))
        #expect(await gate.waitUntilEntered(1), "the scheduled refresh was attempted")
        await gate.release()
        #expect(await chartWaitUntil { state.chartState.refreshFailure == .notReady })
        #expect(state.chartState.snapshot == original, "a 204 keeps the saved rows and age")
        #expect(state.chartState.snapshot?.savedAt == original.savedAt)
        #expect(state.chartState.phase == .ready, "saved rows stay visible beside the not-ready state")
        let requestsAfterNotReady = await chartStatsRequestCount(transport)
        #expect(requestsAfterNotReady == 2)

        clock.advance(to: now.addingTimeInterval(2 * ChartFreshness.interval))
        await turnMainActor(50)
        #expect(
            await chartStatsRequestCount(transport) == requestsAfterNotReady,
            "a 204 scheduled refresh is not retried by another clock advance",
        )
        #expect(state.chartState.snapshot == original)

        await flags.setNotReady(false)
        await runtime.charts?.refresh()
        #expect(state.chartState.refreshFailure == nil)
        #expect(state.chartState.phase == .ready)
        #expect(state.chartState.snapshot?.items.first?.title == "Blondie")
        #expect(state.chartState.snapshot?.savedAt == clock.now)
        #expect(
            await chartStatsRequestCount(transport) == requestsAfterNotReady + 1,
            "the manual retry makes exactly one more stats request",
        )
    }

    @Test func aNotReadyChartWithoutSavedRowsDoesNotPoll() async throws {
        let database = try TemporaryDatabase()
        let now = chartDate(2026, 10, 31, 12)
        let clock = FakeClock(now)
        let flags = ChartFlags()
        await flags.setNotReady(true)
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
        #expect(state.chartState.phase == .notReady)
        #expect(state.chartState.snapshot == nil)
        let requests = await chartStatsRequestCount(transport)
        #expect(requests == 1)

        clock.advance(to: now.addingTimeInterval(2 * ChartFreshness.interval))
        await turnMainActor(50)
        #expect(
            await chartStatsRequestCount(transport) == requests,
            "an empty not-ready chart is not retried automatically",
        )
        #expect(state.chartState.phase == .notReady)
        #expect(state.chartState.snapshot == nil)
    }

    @Test func anAutomaticTotalRefreshDoesNotRetryAFailedList() async throws {
        let database = try TemporaryDatabase()
        let now = chartDate(2026, 10, 31, 12)
        let clock = FakeClock(now)
        let flags = ChartFlags()
        let totalGate = ChartHoldGate()
        let transport = listenBrainzTransport(flags: flags, totalGate: totalGate)
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
        let original = try #require(state.chartState.snapshot)
        #expect(await chartStatsRequestCount(transport) == 1)
        #expect(await chartAccountTotalRequestCount(transport) == 1)

        clock.advance(to: now.addingTimeInterval(5 * 60))
        await flags.setFailing(true)
        await runtime.charts?.refresh()
        #expect(state.chartState.snapshot == original, "the failed list keeps its original rows and age")
        #expect(state.chartState.snapshot?.savedAt == original.savedAt)
        #expect(state.chartState.refreshFailure == .offline)
        #expect(state.chartState.phase == .ready)
        #expect(state.chartState.totals == .account(ChartAccountTotal(
            value: 500,
            serviceName: "ListenBrainz",
            savedAt: clock.now,
        )))
        let statsAfterFailure = await chartStatsRequestCount(transport)
        let totalsAfterFailure = await chartAccountTotalRequestCount(transport)

        await totalGate.startHolding()
        clock.advance(to: now.addingTimeInterval(20 * 60))
        #expect(
            await totalGate.waitUntilEntered(1, timeout: .seconds(10)),
            "the healthy total reached its own deadline",
        )
        await totalGate.release()
        #expect(await chartWaitUntil(timeout: .seconds(10)) {
            if case let .account(total) = state.chartState.totals {
                return total.savedAt == clock.now
            }
            return false
        }, "the total's automatic refresh completed")
        #expect(
            await chartStatsRequestCount(transport) == statsAfterFailure,
            "the total's automatic refresh did not retry the failed list",
        )
        #expect(await chartAccountTotalRequestCount(transport) == totalsAfterFailure + 1)
        #expect(state.chartState.snapshot?.savedAt == original.savedAt)
        #expect(state.chartState.refreshFailure == .offline)

        await totalGate.startHolding()
        clock.advance(to: now.addingTimeInterval(35 * 60))
        #expect(
            await totalGate.waitUntilEntered(1, timeout: .seconds(10)),
            "the total's next deadline still refreshes independently",
        )
        await totalGate.release()
        #expect(await chartWaitUntil(timeout: .seconds(10)) {
            if case let .account(total) = state.chartState.totals {
                return total.savedAt == clock.now
            }
            return false
        }, "the second total refresh completed")
        #expect(
            await chartStatsRequestCount(transport) == statsAfterFailure,
            "a second total deadline still does not retry the failed list",
        )
        #expect(await chartAccountTotalRequestCount(transport) == totalsAfterFailure + 2)
        #expect(state.chartState.snapshot?.savedAt == original.savedAt)
        #expect(state.chartState.refreshFailure == .offline)

        await flags.setFailing(false)
        await runtime.charts?.refresh()
        #expect(await chartStatsRequestCount(transport) == statsAfterFailure + 1)
        #expect(state.chartState.snapshot?.savedAt == clock.now)
        #expect(state.chartState.refreshFailure == nil)
        #expect(state.chartState.phase == .ready)
        #expect(state.chartState.totals == .account(ChartAccountTotal(
            value: 500,
            serviceName: "ListenBrainz",
            savedAt: clock.now,
        )))
    }

    @Test func anAutomaticListRefreshDoesNotRetryAFailedTotal() async throws {
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
        )
        await runtime.start()
        _ = try await runtime.link(kind: .listenBrainz, credential: "token")
        await runtime.charts?.show()
        let originalTotal: ChartAccountTotal
        if case let .account(total) = state.chartState.totals {
            originalTotal = total
        } else {
            #expect(Bool(false), "expected an account total")
            return
        }
        #expect(await chartStatsRequestCount(transport) == 1)
        #expect(await chartAccountTotalRequestCount(transport) == 1)

        clock.advance(to: now.addingTimeInterval(5 * 60))
        await flags.setFailingTotal(true)
        await runtime.charts?.refresh()
        #expect(state.chartState.snapshot?.savedAt == clock.now)
        #expect(state.chartState.refreshFailure == nil)
        #expect(state.chartState.totals == .account(originalTotal), "the failed total keeps its original saved age")
        #expect(state.chartState.totalFailure == .offline)
        let totalsAfterFailure = await chartAccountTotalRequestCount(transport)

        await gate.startHolding()
        clock.advance(to: now.addingTimeInterval(20 * 60))
        #expect(
            await gate.waitUntilEntered(1, timeout: .seconds(10)),
            "the healthy list reached its own deadline",
        )
        await gate.release()
        #expect(await chartWaitUntil(timeout: .seconds(10)) {
            state.chartState.snapshot?.savedAt == clock.now
        }, "the list's automatic refresh completed")
        #expect(
            await chartAccountTotalRequestCount(transport) == totalsAfterFailure,
            "the list's automatic refresh did not retry the failed total",
        )
        #expect(state.chartState.totals == .account(originalTotal))
        #expect(state.chartState.totalFailure == .offline)

        await gate.startHolding()
        clock.advance(to: now.addingTimeInterval(35 * 60))
        #expect(
            await gate.waitUntilEntered(1, timeout: .seconds(10)),
            "the list's next deadline still refreshes independently",
        )
        await gate.release()
        #expect(await chartWaitUntil(timeout: .seconds(10)) {
            state.chartState.snapshot?.savedAt == clock.now
        }, "the second list refresh completed")
        #expect(
            await chartAccountTotalRequestCount(transport) == totalsAfterFailure,
            "a second list deadline still does not retry the failed total",
        )
        #expect(state.chartState.totals == .account(originalTotal))
        #expect(state.chartState.totalFailure == .offline)

        await flags.setFailingTotal(false)
        await runtime.charts?.refresh()
        #expect(await chartAccountTotalRequestCount(transport) == totalsAfterFailure + 1)
        #expect(state.chartState.totals == .account(ChartAccountTotal(
            value: 500,
            serviceName: "ListenBrainz",
            savedAt: clock.now,
        )))
        #expect(state.chartState.totalFailure == nil)
    }

    @Test func hidingStopsTheFreshnessWakeAndShowingAgainRefreshes() async throws {
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
        #expect(await chartStatsRequestCount(transport) == 1)

        runtime.charts?.hide()
        clock.advance(to: now.addingTimeInterval(20 * 60))
        await turnMainActor(50)
        #expect(await chartStatsRequestCount(transport) == 1, "a hidden chart does not refresh itself")

        await runtime.charts?.show()
        #expect(await chartStatsRequestCount(transport) == 2, "showing stale saved charts refreshes them")
        #expect(state.chartState.snapshot?.savedAt == clock.now)
    }

    @Test func deactivatingStopsTheFreshnessWakeAndReactivationRefreshes() async throws {
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
        #expect(await chartStatsRequestCount(transport) == 1)

        runtime.stop()
        clock.advance(to: now.addingTimeInterval(20 * 60))
        await turnMainActor(50)
        #expect(await chartStatsRequestCount(transport) == 1, "deactivation stops the owned freshness wake")

        await runtime.start()
        await runtime.charts?.show()
        #expect(await chartStatsRequestCount(transport) == 2, "reactivation loads the stale saved chart again")
        #expect(state.chartState.snapshot?.savedAt == clock.now)
    }

    @Test func anOlderFreshTotalRefreshesWithoutRefetchingTheFreshList() async throws {
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
                    rows: [("Should Not Be Fetched", "", 1, "artist-mbid")],
                    from: chartDate(2026, 10, 20),
                    end: chartDate(2026, 10, 27),
                    lastUpdated: chartDate(2026, 10, 28, 6),
                )
            }
            if path.contains("listen-count") {
                return listenBrainzCountResponse(500)
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
        let store = try SQLiteListenStore(url: database.url)
        await runtime.start()
        let connection = try await runtime.link(kind: .listenBrainz, credential: "token")

        let listKey = ChartCacheKey(
            kind: .list,
            source: .service,
            serviceKind: .listenBrainz,
            endpoint: connection.endpoint.description,
            account: connection.identity,
            chartType: .artists,
            period: .allTime,
        )
        let cachedList = ChartSnapshot(
            scopeKey: listKey.rawKey,
            type: .artists,
            period: .allTime,
            items: [ChartItem(
                rank: 1,
                title: "Cached Artist",
                count: 5,
                identityKey: "mbid:cached-artist",
            )],
            localTotal: nil,
            omittedCount: 0,
            returnedRange: nil,
            countUnit: .listens,
            savedAt: now,
        )
        try await store.saveChartCache(
            ChartCacheEntry(savedAt: now, payload: JSONEncoder().encode(cachedList)),
            for: listKey,
        )
        let totalKey = ChartCacheKey(
            kind: .total,
            source: .service,
            serviceKind: .listenBrainz,
            endpoint: connection.endpoint.description,
            account: connection.identity,
            chartType: nil,
            period: .allTime,
        )
        let oldTotal = ChartAccountTotal(
            value: 4_321,
            serviceName: "ListenBrainz",
            savedAt: now.addingTimeInterval(-10 * 60),
        )
        try await store.saveChartCache(
            ChartCacheEntry(savedAt: oldTotal.savedAt, payload: JSONEncoder().encode(oldTotal)),
            for: totalKey,
        )

        await runtime.charts?.show()
        #expect(state.chartState.snapshot?.items.first?.title == "Cached Artist")
        #expect(state.chartState.totals == .account(oldTotal))
        #expect(await chartStatsRequestCount(transport) == 0)
        #expect(await chartAccountTotalRequestCount(transport) == 0)

        clock.advance(to: now.addingTimeInterval(5 * 60))
        #expect(await chartWaitUntil {
            if case let .account(total) = state.chartState.totals {
                return total.value == 500
            }
            return false
        }, "the older total's own deadline refreshed it")
        #expect(await chartStatsRequestCount(transport) == 0, "the fresh list was not refetched")
        #expect(await chartAccountTotalRequestCount(transport) == 1)
        #expect(state.chartState.snapshot?.savedAt == now, "the list keeps its own saved age")
        #expect(state.chartState.totals == .account(ChartAccountTotal(
            value: 500,
            serviceName: "ListenBrainz",
            savedAt: clock.now,
        )))
    }

    @Test func anOldFallbackKeyStaysReadableUntilASuccessfulRefresh() async throws {
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
                    throw URLError(.notConnectedToInternet)
                }
                return listenBrainzStatsResponse(
                    type: .artists,
                    rows: [("Same Name", "", 5, "")],
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
        let store = try SQLiteListenStore(url: database.url)
        await runtime.start()
        let connection = try await runtime.link(kind: .listenBrainz, credential: "token")
        let listKey = ChartCacheKey(
            kind: .list,
            source: .service,
            serviceKind: .listenBrainz,
            endpoint: connection.endpoint.description,
            account: connection.identity,
            chartType: .artists,
            period: .week,
        )
        let oldSavedAt = now.addingTimeInterval(-20 * 60)
        let oldSnapshot = ChartSnapshot(
            scopeKey: listKey.rawKey,
            type: .artists,
            period: .week,
            items: [ChartItem(
                rank: 1,
                title: "Same Name",
                count: 5,
                identityKey: "fallback:artists:same name\u{1F}",
            )],
            localTotal: nil,
            omittedCount: 0,
            returnedRange: nil,
            countUnit: .listens,
            savedAt: oldSavedAt,
        )
        try await store.saveChartCache(
            ChartCacheEntry(savedAt: oldSavedAt, payload: JSONEncoder().encode(oldSnapshot)),
            for: listKey,
        )
        await flags.setFailing(true)
        await runtime.charts?.show()
        #expect(state.chartState.snapshot?.items.first?.identityKey == "fallback:artists:same name\u{1F}")
        #expect(state.chartState.refreshFailure == .offline, "offline data is retained rather than discarded")

        await flags.setFailing(false)
        await runtime.charts?.refresh()
        #expect(state.chartState.refreshFailure == nil)
        #expect(
            state.chartState.snapshot?.items.first?.identityKey.hasPrefix("fallback:listenbrainz:artists:") == true,
            "a successful refresh writes the source-scoped key",
        )
        #expect(try await store.chartCacheCount() == 1)
    }

    @Test func aSavedListenBrainzSpanSurvivesRestartFailureAndNotReady() async throws {
        let database = try TemporaryDatabase()
        let now = chartDate(2026, 10, 31, 12)
        let clock = FakeClock(now)
        let credentials = MemoryCredentialStore()
        let flags = ChartFlags()
        let transport = listenBrainzTransport(flags: flags)
        let selection = chartSelection(
            source: .service,
            period: .week,
            now: now,
            calendar: chartCalendar(utc),
        )
        let state = TracklogAppState()
        let runtime = makeChartRuntime(
            database: database,
            clock: clock,
            transport: transport,
            state: state,
            selection: selection,
            calendarBox: ChartCalendarBox(chartCalendar(utc)),
            credentials: credentials,
        )
        await runtime.start()
        _ = try await runtime.link(kind: .listenBrainz, credential: "token")
        await runtime.charts?.show()

        let original = try #require(state.chartState.snapshot?.returnedRange)
        #expect(original.start == chartDate(2026, 10, 20))
        #expect(original.end == chartDate(2026, 10, 27))
        let fresh = ChartCopy.returnedRangeLabel(
            original,
            period: .week,
            serviceKind: .listenBrainz,
            now: clock.now,
            calendar: chartCalendar(utc),
        )
        #expect(fresh.contains("Oct 20, 2026"), "\(fresh)")
        #expect(fresh.contains("Oct 26, 2026"), "\(fresh)")
        #expect(fresh.contains("data ends 4 d ago"), "\(fresh)")

        runtime.stop()
        clock.advance(to: now.addingTimeInterval(20 * 86_400))
        await flags.setFailing(true)
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
        #expect(offlineState.chartState.snapshot?.returnedRange == original)
        #expect(offlineState.chartState.refreshFailure == .offline)
        let restored = try ChartCopy.returnedRangeLabel(
            #require(offlineState.chartState.snapshot?.returnedRange),
            period: .week,
            serviceKind: .listenBrainz,
            now: clock.now,
            calendar: chartCalendar(utc),
        )
        #expect(restored.contains("data ends 24 d ago"), "the saved span's age keeps growing: \(restored)")

        await flags.setFailing(false)
        await flags.setNotReady(true)
        await offlineRuntime.charts?.refresh()
        #expect(offlineState.chartState.snapshot?.returnedRange == original)
        #expect(offlineState.chartState.refreshFailure == .notReady)
        let notReady = try ChartCopy.returnedRangeLabel(
            #require(offlineState.chartState.snapshot?.returnedRange),
            period: .week,
            serviceKind: .listenBrainz,
            now: clock.now,
            calendar: chartCalendar(utc),
        )
        #expect(notReady == restored)
    }

    @Test func aListenBrainzRateLimitKeepsSavedRowsAndItsRetryAfter() async throws {
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
        await flags.setRateLimited(true)
        runtime.charts?.hide()
        await runtime.charts?.show()

        #expect(state.chartState.snapshot == original)
        #expect(state.chartState.phase == .ready)
        #expect(state.chartState.refreshFailure == .rateLimited(retryAfter: 30))
        let stats = await transport.recordedRequests.filter {
            chartListenBrainzPath($0).contains("/stats/user/")
        }
        #expect(stats.count == 2, "the initial read and the saved refresh each made one real adapter request")
        #expect(stats.last?.headers["Authorization"] == "Token token")
        #expect(stats.last?.url.path.contains("/user/listener/artists") == true)
    }

    // MARK: - Fixtures

    private func chartStatsRequestCount(_ transport: ChartHTTPTransport) async -> Int {
        await transport.recordedRequests.filter {
            chartListenBrainzPath($0).contains("/stats/user/")
        }.count
    }

    private func chartAccountTotalRequestCount(_ transport: ChartHTTPTransport) async -> Int {
        await transport.recordedRequests.filter {
            chartListenBrainzPath($0).contains("listen-count")
        }.count
    }

    private func chartWaitForStatsRequestCount(
        _ transport: ChartHTTPTransport,
        _ target: Int,
        timeout: Duration = .seconds(5),
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while await chartStatsRequestCount(transport) < target {
            if ContinuousClock.now >= deadline {
                return false
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }
}

/// Counts manual refreshes that joined an in-flight read, so a test can wait
/// for both callers instead of guessing with task yields.
@MainActor
private final class RefreshJoinCounter {
    private var count = 0

    func signal() {
        count += 1
    }

    func wait(for target: Int, timeout: Duration = .seconds(5)) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while count < target {
            if ContinuousClock.now >= deadline {
                return false
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }
}

/// Holds the first chart cache read so a test can issue a manual refresh while
/// the initial show is still deciding whether it needs the network.
private actor HeldCacheChartStore: ChartStore {
    private let base: SQLiteListenStore
    private var shouldHold = false
    private var readEntered = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(base: SQLiteListenStore) {
        self.base = base
    }

    func holdNextCacheRead() {
        shouldHold = true
        readEntered = false
    }

    @discardableResult
    func waitUntilCacheRead(timeout: Duration = .seconds(5)) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !readEntered {
            if ContinuousClock.now >= deadline {
                return false
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    func releaseCacheRead() {
        shouldHold = false
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func chartCache(_ key: ChartCacheKey) async throws -> ChartCacheEntry? {
        if shouldHold {
            shouldHold = false
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
                readEntered = true
            }
        }
        return try await base.chartCache(key)
    }

    func saveChartCache(_ entry: ChartCacheEntry, for key: ChartCacheKey) async throws {
        try await base.saveChartCache(entry, for: key)
    }

    func evictChartCaches(endpoint: String, account: String) async throws {
        try await base.evictChartCaches(endpoint: endpoint, account: account)
    }

    func pruneChartCaches() async throws {
        try await base.pruneChartCaches()
    }

    func clearLocalCustomChartCaches() async throws {
        try await base.clearLocalCustomChartCaches()
    }

    func localChart(
        type: ChartType,
        window: LocalChartWindow,
        limit: Int,
    ) async throws -> LocalChartAggregate {
        try await base.localChart(type: type, window: window, limit: limit)
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

// swiftlint:enable file_length function_body_length type_body_length
