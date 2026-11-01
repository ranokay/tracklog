// swiftlint:disable file_length type_body_length function_body_length cyclomatic_complexity function_parameter_count
import Foundation

/// The one statistics boundary shared by local history and the service
/// adapters. Views publish nothing themselves; every row, total, saved age and
/// failure in ``ChartViewState`` comes from here.
@MainActor
public final class ChartReadModel {
    public let state: TracklogAppState
    public private(set) var selection: ChartSelection
    public private(set) var isActive = false
    public private(set) var isShowing = false

    private let store: any ChartStore
    private let credentials: any CredentialStore
    private let clients: [ServiceKind: any ChartServiceReading]
    private let artworkStore: (any ArtworkStore)?
    private let clock: any Clock
    private let calendar: @MainActor () -> Calendar
    private let persistSelection: (@MainActor (ChartSelection) -> Void)?
    private let log: (@MainActor (String) -> Void)?

    private var generation = 0
    private var refreshTask: Task<ChartLoadOutcome, Never>?
    private var refreshTaskIsForced = false
    private var pendingForcedRefresh: UUID?
    private var artworkTask: Task<Void, Never>?
    private var activeToken: UUID?
    private var currentScopeKey: String?
    private var lastConnectionKey = "none"
    private var observers: [NSObjectProtocol] = []
    private var didPruneCache = false
    /// Installed only by focused refresh-join tests; production leaves nil.
    private var refreshJoinObserver: (@MainActor () -> Void)?

    func setRefreshJoinObserver(_ observer: (@MainActor () -> Void)?) {
        refreshJoinObserver = observer
    }

    public init(
        state: TracklogAppState,
        store: any ChartStore,
        credentials: any CredentialStore,
        serviceClients: [any ChartServiceReading],
        artworkStore: (any ArtworkStore)? = nil,
        clock: any Clock,
        calendar: @escaping @MainActor () -> Calendar = { ChartCalendar.current },
        selection: ChartSelection = .standard,
        persistSelection: (@MainActor (ChartSelection) -> Void)? = nil,
        log: (@MainActor (String) -> Void)? = nil,
    ) {
        self.state = state
        self.store = store
        self.credentials = credentials
        var byKind: [ServiceKind: any ChartServiceReading] = [:]
        for client in serviceClients {
            byKind[client.kind] = client
        }
        clients = byKind
        self.artworkStore = artworkStore
        self.clock = clock
        self.calendar = calendar
        self.selection = selection
        self.persistSelection = persistSelection
        self.log = log
        lastConnectionKey = Self.connectionKey(state.currentConnection)
        state.chartState = ChartViewState(selection: selection)
    }

    // MARK: - Lifecycle

    public func activate() {
        guard !isActive else { return }
        isActive = true
        didPruneCache = false
        lastConnectionKey = Self.connectionKey(state.currentConnection)
        state.chartState = ChartViewState(selection: selection)
        registerObservers()
    }

    public func deactivate() {
        guard isActive || isShowing else { return }
        isActive = false
        isShowing = false
        generation += 1
        refreshTask?.cancel()
        refreshTask = nil
        refreshTaskIsForced = false
        pendingForcedRefresh = nil
        artworkTask?.cancel()
        artworkTask = nil
        activeToken = nil
        currentScopeKey = nil
        removeObservers()
        state.chartState.isRefreshing = false
    }

    /// The Charts section became visible. History-first is the takeover's
    /// concern; this only starts the read.
    public func show() async {
        guard isActive else { return }
        isShowing = true
        lastConnectionKey = Self.connectionKey(state.currentConnection)
        await load(force: false)
    }

    /// The section was dismissed or switched away. The display and the durable
    /// cache survive; owned work does not.
    public func hide() {
        guard isShowing else { return }
        isShowing = false
        generation += 1
        refreshTask?.cancel()
        refreshTask = nil
        refreshTaskIsForced = false
        pendingForcedRefresh = nil
        artworkTask?.cancel()
        artworkTask = nil
        activeToken = nil
        currentScopeKey = nil
        state.chartState.isRefreshing = false
    }

    /// Both notifications change a resolved local window even though the
    /// selection has not changed.
    public func environmentChanged() async {
        guard isActive, isShowing else { return }
        let effective = effectiveSource(
            for: selection,
            connection: state.currentConnection,
        )
        guard effective.isLocal else { return }
        generation += 1
        refreshTask?.cancel()
        refreshTask = nil
        refreshTaskIsForced = false
        pendingForcedRefresh = nil
        activeToken = nil
        currentScopeKey = nil
        state.chartState.snapshot = nil
        state.chartState.phase = .loading
        state.chartState.totals = .none
        state.chartState.refreshFailure = nil
        await load(force: false)
    }

    // MARK: - Selection

    public func selectSource(_ source: ChartSourceSelection) async {
        var new = selection
        new.source = source
        clampServicePeriod(&new)
        applySelection(new)
        if isShowing {
            await load(force: false)
        }
    }

    public func selectPeriod(_ period: ChartPeriod) async {
        var new = selection
        new.period = period
        clampServicePeriod(&new)
        applySelection(new)
        if isShowing {
            await load(force: false)
        }
    }

    public func selectType(_ type: ChartType) async {
        var new = selection
        new.type = type
        applySelection(new)
        if isShowing {
            await load(force: false)
        }
    }

    /// Saving from Settings is the only way a Custom range enters the
    /// selection.
    public func saveCustomRange(start: ChartDate, end: ChartDate) async throws {
        guard end >= start else { throw ChartValidationError.reversedCustomRange }
        try await store.clearLocalCustomChartCaches()
        var new = selection
        new.source = .local
        new.period = .custom
        new.customStart = start
        new.customEnd = end
        applySelection(new)
        if isShowing {
            await load(force: false)
        }
    }

    /// Settings' Open Charts always returns to the last saved local Custom
    /// dates, even after the listener has browsed another source or period.
    public func selectSavedCustomRange() async {
        var new = selection
        new.source = .local
        new.period = .custom
        applySelection(new)
        if isShowing {
            await load(force: false)
        }
    }

    /// Manual Refresh. Repeated calls for the same scope wait on the one
    /// request already in flight.
    public func refresh() async {
        guard isActive, isShowing else { return }
        await load(force: true)
    }

    // MARK: - Connections

    /// The runtime calls this after every connection-list or auth-state
    /// publication. A read-source change clears the old account's rows before
    /// any new request can answer.
    public func connectionsChanged() {
        guard isActive else { return }
        let key = Self.connectionKey(state.currentConnection)
        guard key != lastConnectionKey else { return }
        lastConnectionKey = key

        guard selection.source == .service else {
            // Local charts are global; only the explanatory source note
            // depends on the connection.
            return
        }
        generation += 1
        refreshTask?.cancel()
        refreshTask = nil
        refreshTaskIsForced = false
        pendingForcedRefresh = nil
        artworkTask?.cancel()
        artworkTask = nil
        activeToken = nil
        currentScopeKey = nil
        state.chartState = ChartViewState(selection: selection)
        if isShowing {
            Task { [weak self] in
                await self?.load(force: false)
            }
        }
    }

    // MARK: - Loading

    private func applySelection(_ new: ChartSelection) {
        guard new != selection else { return }
        selection = new
        persistSelection?(new)
        generation += 1
        refreshTask?.cancel()
        refreshTask = nil
        refreshTaskIsForced = false
        pendingForcedRefresh = nil
        artworkTask?.cancel()
        artworkTask = nil
        activeToken = nil
        currentScopeKey = nil
        state.chartState = ChartViewState(selection: new)
    }

    private func load(force: Bool) async {
        guard isActive, isShowing else { return }
        normalizeCurrentSelection()
        let request: ChartRequest
        do {
            request = try resolvedRequest()
        } catch {
            state.chartState.phase = .failed(.invalidRange)
            state.chartState.isRefreshing = false
            return
        }

        if case .none = request.effective {
            currentScopeKey = nil
            state.chartState.selection = request.selection
            state.chartState.phase = .noConnection
            state.chartState.snapshot = nil
            state.chartState.totals = .none
            state.chartState.refreshFailure = nil
            state.chartState.totalFailure = nil
            state.chartState.effectiveSource = .none
            state.chartState.periodDetail = nil
            state.chartState.isRefreshing = false
            return
        }

        if currentScopeKey == request.scopeKey, let refreshTask {
            let isForced = refreshTaskIsForced
            let waiterToken = activeToken
            if force, !isForced, let waiterToken {
                pendingForcedRefresh = waiterToken
                refreshJoinObserver?()
            }
            let outcome = await refreshTask.value
            if force, !isForced, let waiterToken, pendingForcedRefresh == waiterToken {
                pendingForcedRefresh = nil
                if !outcome.satisfies(request), isCurrent(request) {
                    await load(force: true)
                }
            }
            return
        }

        currentScopeKey = request.scopeKey
        state.chartState.selection = request.selection
        state.chartState.effectiveSource = request.effective
        state.chartState.periodDetail = periodDetail(for: request)
        if state.chartState.snapshot?.scopeKey != request.listKey?.rawKey {
            state.chartState.snapshot = nil
            state.chartState.phase = .loading
        }

        let token = UUID()
        pendingForcedRefresh = nil
        activeToken = token
        refreshTaskIsForced = force
        let task = Task { [weak self] in
            guard let self else { return ChartLoadOutcome() }
            var outcome = await performLoad(request, force: force)
            while pendingForcedRefresh == token, isCurrent(request) {
                pendingForcedRefresh = nil
                if outcome.satisfies(request) {
                    break
                }
                guard activeToken == token else { break }
                refreshTaskIsForced = true
                let forcedOutcome = await performLoad(request, force: true)
                outcome.merge(forcedOutcome)
            }
            if activeToken == token {
                refreshTask = nil
                refreshTaskIsForced = false
                activeToken = nil
            }
            return outcome
        }
        refreshTask = task
        _ = await task.value
    }

    /// Returns which reads this pass actually attempted, so an explicit
    /// refresh that arrived during a cache-only or total-only pass can force
    /// the missing read without duplicating one already underway.
    private func performLoad(_ request: ChartRequest, force: Bool) async -> ChartLoadOutcome {
        if !didPruneCache {
            didPruneCache = true
            do {
                try await store.pruneChartCaches()
            } catch {
                log?("Chart cache maintenance failed: \(error)")
            }
        }

        var cachedSnapshot: ChartSnapshot?
        if let key = request.listKey {
            cachedSnapshot = await loadCachedSnapshot(for: key)
        }
        var cachedTotal: ChartAccountTotal?
        if let key = request.totalKey {
            cachedTotal = await loadCachedTotal(for: key)
        }
        guard isCurrent(request) else { return ChartLoadOutcome() }

        if let cachedSnapshot,
           state.chartState.snapshot == nil
           || cachedSnapshot.savedAt > (state.chartState.snapshot?.savedAt ?? .distantPast) {
            publish(snapshot: cachedSnapshot, request: request)
            scheduleArtworkLoad(cachedSnapshot)
        } else if let snapshot = state.chartState.snapshot,
                  snapshot.scopeKey == request.listKey?.rawKey {
            applyPhase(for: snapshot, request: request)
        }

        let snapshot = currentSnapshot(for: request)
        let listNeedsRefresh = force
            || snapshot == nil
            || isStale(snapshot?.savedAt)

        let serviceAllTime = request.selection.period == .allTime && request.serviceKind != nil
        var total: ChartAccountTotal?
        if serviceAllTime {
            if let cachedTotal {
                if case let .account(existing) = state.chartState.totals {
                    if cachedTotal.savedAt > existing.savedAt {
                        state.chartState.totals = .account(cachedTotal)
                        total = cachedTotal
                    } else {
                        total = existing
                    }
                } else {
                    state.chartState.totals = .account(cachedTotal)
                    total = cachedTotal
                }
            } else if case let .account(existing) = state.chartState.totals {
                total = existing
            }
        } else if request.serviceKind != nil {
            state.chartState.totals = .unavailable(.rangeTotals)
        } else if let snapshot, let localTotal = snapshot.localTotal {
            state.chartState.totals = .local(localTotal)
        }

        let totalNeedsRefresh = serviceAllTime
            && (force || total == nil || isStale(total?.savedAt))

        if !listNeedsRefresh, !totalNeedsRefresh {
            state.chartState.isRefreshing = false
            return ChartLoadOutcome()
        }

        state.chartState.isRefreshing = true
        state.chartState.refreshFailure = nil
        if serviceAllTime, total == nil {
            state.chartState.totals = .loading
        }

        let outcome = ChartLoadOutcome(
            fetchedList: listNeedsRefresh,
            fetchedTotal: totalNeedsRefresh,
        )
        if request.serviceKind != nil {
            await loadService(request, force: force)
        } else {
            await loadLocal(request)
        }
        guard isCurrent(request) else { return outcome }
        state.chartState.isRefreshing = false
        return outcome
    }

    private func loadLocal(_ request: ChartRequest) async {
        guard let key = request.listKey, let window = request.window else { return }
        do {
            let aggregate = try await store.localChart(
                type: request.selection.type,
                window: window,
                limit: ChartLimits.topEntityLimit,
            )
            guard isCurrent(request) else { return }
            let snapshot = ChartSnapshot(
                scopeKey: key.rawKey,
                type: request.selection.type,
                period: request.selection.period,
                items: aggregate.items,
                localTotal: aggregate.total,
                omittedCount: aggregate.omittedCount,
                returnedRange: nil,
                countUnit: .listens,
                savedAt: clock.now,
            )
            publish(snapshot: snapshot, request: request)
            state.chartState.refreshFailure = nil
            state.chartState.totals = .local(aggregate.total)
            await save(snapshot: snapshot, for: key, request: request)
            scheduleArtworkLoad(snapshot)
        } catch {
            guard isCurrent(request) else { return }
            if currentSnapshot(for: request) != nil {
                state.chartState.refreshFailure = .localRead
            } else {
                state.chartState.phase = .failed(.localRead)
            }
        }
    }

    private func loadService(_ request: ChartRequest, force: Bool) async {
        guard isCurrent(request),
              case let .service(connectionID, kind, _, _, _) = request.effective,
              let connection = request.connection,
              let client = clients[kind],
              let listKey = request.listKey
        else { return }

        if connection.authState != .signedIn {
            recordListFailure(.needsSignIn, request: request)
            recordTotalFailure(.needsSignIn, request: request)
            return
        }

        let credential: String
        do {
            guard let stored = try await credentials.credential(forConnection: connectionID),
                  !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                guard isCurrent(request) else { return }
                recordListFailure(.needsSignIn, request: request)
                recordTotalFailure(.needsSignIn, request: request)
                return
            }
            credential = stored
        } catch {
            guard isCurrent(request) else { return }
            recordListFailure(.needsSignIn, request: request)
            recordTotalFailure(.needsSignIn, request: request)
            return
        }
        guard isCurrent(request) else { return }

        let snapshot = currentSnapshot(for: request)
        let listNeedsRefresh = force
            || snapshot == nil
            || isStale(snapshot?.savedAt)

        if listNeedsRefresh {
            do {
                let page = try await client.top(
                    request.selection.type,
                    period: request.selection.period,
                    connection: connection,
                    credential: credential,
                    limit: ChartLimits.topEntityLimit,
                )
                guard isCurrent(request) else { return }
                let updated = ChartSnapshot(
                    scopeKey: listKey.rawKey,
                    type: request.selection.type,
                    period: request.selection.period,
                    items: Array(page.items.prefix(ChartLimits.topEntityLimit)),
                    localTotal: nil,
                    omittedCount: 0,
                    returnedRange: page.returnedRange,
                    countUnit: kind == .lastFM ? .plays : .listens,
                    savedAt: clock.now,
                )
                publish(snapshot: updated, request: request)
                state.chartState.refreshFailure = nil
                await save(snapshot: updated, for: listKey, request: request)
            } catch {
                guard isCurrent(request) else { return }
                recordListFailure(chartFailure(for: error), request: request)
            }
        }

        guard request.selection.period == .allTime, let totalKey = request.totalKey else {
            return
        }

        await loadServiceTotal(
            client: client,
            connection: connection,
            credential: credential,
            key: totalKey,
            request: request,
            force: force,
        )
    }

    private func loadServiceTotal(
        client: any ChartServiceReading,
        connection: Connection,
        credential: String,
        key: ChartCacheKey,
        request: ChartRequest,
        force: Bool,
    ) async {
        let existing = currentTotal()
        guard force || existing == nil || isStale(existing?.savedAt) else { return }
        do {
            let value = try await client.allTimeAccountTotal(
                connection: connection,
                credential: credential,
            )
            guard isCurrent(request) else { return }
            let total = ChartAccountTotal(
                value: value,
                serviceName: connection.kind.displayName,
                savedAt: clock.now,
            )
            state.chartState.totals = .account(total)
            state.chartState.totalFailure = nil
            await save(total: total, for: key, request: request)
        } catch {
            guard isCurrent(request) else { return }
            recordTotalFailure(chartFailure(for: error), request: request)
        }
    }

    // MARK: - Publication

    private func publish(snapshot: ChartSnapshot, request: ChartRequest) {
        state.chartState.snapshot = snapshot
        state.chartState.selection = request.selection
        state.chartState.effectiveSource = request.effective
        state.chartState.periodDetail = periodDetail(for: request)
        applyPhase(for: snapshot, request: request)
        if request.serviceKind == nil, let localTotal = snapshot.localTotal {
            state.chartState.totals = .local(localTotal)
        }
    }

    private func applyPhase(for snapshot: ChartSnapshot, request: ChartRequest) {
        if snapshot.items.isEmpty {
            if request.serviceKind == nil {
                if let total = snapshot.localTotal, total > 0, snapshot.omittedCount > 0 {
                    state.chartState.phase = .noMetadata(omitted: snapshot.omittedCount)
                } else {
                    state.chartState.phase = .empty
                }
            } else {
                state.chartState.phase = .empty
            }
        } else {
            state.chartState.phase = .ready
        }
    }

    private func recordListFailure(_ failure: ChartFailure, request: ChartRequest) {
        if currentSnapshot(for: request) != nil {
            state.chartState.refreshFailure = failure
        } else if failure == .notReady {
            state.chartState.phase = .notReady
        } else {
            state.chartState.phase = .failed(failure)
        }
    }

    private func recordTotalFailure(_ failure: ChartFailure, request: ChartRequest) {
        guard request.selection.period == .allTime, request.serviceKind != nil else { return }
        if case let .account(total) = state.chartState.totals {
            state.chartState.totalFailure = failure
            // The successful account count remains, with its own age.
            state.chartState.totals = .account(total)
        } else {
            state.chartState.totals = .unavailable(.accountTotal(failure))
            state.chartState.totalFailure = failure
        }
    }

    private func currentSnapshot(for request: ChartRequest) -> ChartSnapshot? {
        guard let snapshot = state.chartState.snapshot,
              snapshot.scopeKey == request.listKey?.rawKey
        else { return nil }
        return snapshot
    }

    private func currentTotal() -> ChartAccountTotal? {
        guard case let .account(total) = state.chartState.totals else { return nil }
        return total
    }

    // MARK: - Cache

    private func loadCachedSnapshot(for key: ChartCacheKey) async -> ChartSnapshot? {
        guard let entry = try? await store.chartCache(key),
              let decoded = try? JSONDecoder().decode(ChartSnapshot.self, from: entry.payload),
              decoded.scopeKey == key.rawKey,
              decoded.type == key.chartType,
              decoded.period == key.period
        else { return nil }
        var snapshot = decoded
        snapshot.savedAt = entry.savedAt
        return snapshot
    }

    private func loadCachedTotal(for key: ChartCacheKey) async -> ChartAccountTotal? {
        guard let entry = try? await store.chartCache(key),
              let decoded = try? JSONDecoder().decode(ChartAccountTotal.self, from: entry.payload)
        else { return nil }
        var total = decoded
        total.savedAt = entry.savedAt
        return total
    }

    private func save(snapshot: ChartSnapshot, for key: ChartCacheKey, request: ChartRequest) async {
        guard isCurrent(request) else { return }
        do {
            let payload = try JSONEncoder().encode(snapshot)
            try await store.saveChartCache(
                ChartCacheEntry(savedAt: snapshot.savedAt, payload: payload),
                for: key,
            )
        } catch {
            // A displayable chart is not discarded because its cache write
            // failed; the next refresh tries again.
            log?("Saving the chart cache failed: \(error)")
        }
    }

    private func save(total: ChartAccountTotal, for key: ChartCacheKey, request: ChartRequest) async {
        guard isCurrent(request) else { return }
        do {
            let payload = try JSONEncoder().encode(total)
            try await store.saveChartCache(
                ChartCacheEntry(savedAt: total.savedAt, payload: payload),
                for: key,
            )
        } catch {
            log?("Saving the account total failed: \(error)")
        }
    }

    // MARK: - Artwork

    private func scheduleArtworkLoad(_ snapshot: ChartSnapshot) {
        guard let artworkStore else { return }
        let hashes = Set(snapshot.items.compactMap(\.artworkHash))
            .filter { state.artworkByHash[$0] == nil }
        guard !hashes.isEmpty else { return }
        artworkTask?.cancel()
        artworkTask = Task { [weak self] in
            for hash in hashes {
                guard !Task.isCancelled, let self, isActive else { return }
                guard let data = try? await artworkStore.artwork(for: hash) else { continue }
                guard !Task.isCancelled, isActive else { return }
                state.artworkByHash[hash] = data
            }
        }
    }

    // MARK: - Request resolution

    private struct ChartLoadOutcome {
        var fetchedList = false
        var fetchedTotal = false

        func satisfies(_ request: ChartRequest) -> Bool {
            fetchedList && (request.totalKey == nil || fetchedTotal)
        }

        mutating func merge(_ other: ChartLoadOutcome) {
            fetchedList = fetchedList || other.fetchedList
            fetchedTotal = fetchedTotal || other.fetchedTotal
        }
    }

    private struct ChartRequest {
        let generation: Int
        let selection: ChartSelection
        let effective: ChartEffectiveSource
        let connection: Connection?
        let window: LocalChartWindow?
        let listKey: ChartCacheKey?
        let totalKey: ChartCacheKey?
        let serviceKind: ServiceKind?
        let scopeKey: String
    }

    private func resolvedRequest() throws -> ChartRequest {
        let resolved = selection
        let connection = state.currentConnection
        let effective = effectiveSource(for: resolved, connection: connection)

        let calendar = calendar()
        let window = try ChartWindows.resolve(
            selection: resolved,
            now: clock.now,
            calendar: calendar,
        )

        switch effective {
        case .none:
            return ChartRequest(
                generation: generation,
                selection: resolved,
                effective: .none,
                connection: nil,
                window: nil,
                listKey: nil,
                totalKey: nil,
                serviceKind: nil,
                scopeKey: "none",
            )
        case let .local(reason):
            let key = ChartCacheKey(
                kind: .list,
                source: .local,
                chartType: resolved.type,
                period: resolved.period,
                timeZoneID: window.timeZoneID,
                windowStart: window.range?.lowerBound,
                windowEnd: window.range?.upperBound,
            )
            return ChartRequest(
                generation: generation,
                selection: resolved,
                effective: .local(reason: reason),
                connection: connection,
                window: window,
                listKey: key,
                totalKey: nil,
                serviceKind: nil,
                scopeKey: "\(key.rawKey)|local:\(String(describing: reason))",
            )
        case let .service(_, kind, _, _, _):
            guard let connection else {
                return ChartRequest(
                    generation: generation,
                    selection: resolved,
                    effective: .none,
                    connection: nil,
                    window: nil,
                    listKey: nil,
                    totalKey: nil,
                    serviceKind: nil,
                    scopeKey: "none",
                )
            }
            let listKey = ChartCacheKey(
                kind: .list,
                source: .service,
                serviceKind: kind,
                endpoint: connection.endpoint.description,
                account: connection.identity,
                chartType: resolved.type,
                period: resolved.period,
            )
            let totalKey: ChartCacheKey? = resolved.period == .allTime
                ? ChartCacheKey(
                    kind: .total,
                    source: .service,
                    serviceKind: kind,
                    endpoint: connection.endpoint.description,
                    account: connection.identity,
                    chartType: nil,
                    period: .allTime,
                )
                : nil
            return ChartRequest(
                generation: generation,
                selection: resolved,
                effective: effective,
                connection: connection,
                window: window,
                listKey: listKey,
                totalKey: totalKey,
                serviceKind: kind,
                scopeKey: "\(listKey.rawKey)|service:\(kind.rawValue):\(connection.identity)",
            )
        }
    }

    private func effectiveSource(
        for selection: ChartSelection,
        connection: Connection?,
    ) -> ChartEffectiveSource {
        if selection.source == .local {
            return .local(reason: .selected)
        }
        guard let connection else { return .none }
        guard clients[connection.kind] != nil else {
            return .local(reason: .unsupported(connection.kind))
        }
        return .service(
            connectionID: connection.id ?? -1,
            kind: connection.kind,
            endpoint: connection.endpoint,
            identity: connection.identity,
            displayName: connection.displayName,
        )
    }

    /// A service source has no Today or Custom range. A Libre.fm fallback is
    /// already local, so it keeps whichever period the listener chose.
    private func clampServicePeriod(_ selection: inout ChartSelection) {
        guard selection.source == .service,
              let connection = state.currentConnection,
              clients[connection.kind] != nil,
              selection.period.isLocalOnly
        else { return }
        selection.period = .week
    }

    /// A persisted service selection may predate the current connection, or
    /// the connection may have changed since it was saved. Clamp it once
    /// before building a request so the request and the published selection
    /// can never disagree.
    private func normalizeCurrentSelection() {
        var resolved = selection
        clampServicePeriod(&resolved)
        guard resolved != selection else { return }
        selection = resolved
        persistSelection?(resolved)
        state.chartState.selection = resolved
    }

    private func periodDetail(for request: ChartRequest) -> String? {
        guard let kind = request.serviceKind else { return nil }
        return request.selection.period.serviceSemantics(for: kind)
    }

    private func isCurrent(_ request: ChartRequest) -> Bool {
        guard isActive,
              isShowing,
              generation == request.generation,
              selection == request.selection
        else { return false }
        let effective = effectiveSource(for: request.selection, connection: state.currentConnection)
        return effective == request.effective
    }

    private func isStale(_ savedAt: Date?) -> Bool {
        guard let savedAt else { return true }
        return clock.now.timeIntervalSince(savedAt) >= ChartFreshness.interval
    }

    private func chartFailure(for error: any Error) -> ChartFailure {
        if let chart = error as? ChartServiceError, chart == .notReady {
            return .notReady
        }
        if let failure = error as? ServiceFailure {
            switch failure {
            case .auth:
                return .needsSignIn
            case .appCredentialAuth:
                return .appCredentials
            case let .rateLimited(retryAfter):
                return .rateLimited(retryAfter: retryAfter)
            case .retryable:
                return .offline
            case let .rejected(message):
                return .service(message)
            }
        }
        return .offline
    }

    // MARK: - Environment

    private func registerObservers() {
        removeObservers()
        let center = NotificationCenter.default
        for name in [
            NSNotification.Name.NSSystemTimeZoneDidChange,
            NSNotification.Name.NSCalendarDayChanged,
        ] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.environmentChanged()
                }
            })
        }
    }

    private func removeObservers() {
        let center = NotificationCenter.default
        for observer in observers {
            center.removeObserver(observer)
        }
        observers.removeAll()
    }

    private static func connectionKey(_ connection: Connection?) -> String {
        guard let connection else { return "none" }
        return [
            String(connection.id ?? -1),
            connection.kind.rawValue,
            connection.endpoint.description,
            connection.identity,
            connection.authState.rawValue,
        ].joined(separator: "\u{1F}")
    }
}

// swiftlint:enable file_length type_body_length function_body_length cyclomatic_complexity function_parameter_count
