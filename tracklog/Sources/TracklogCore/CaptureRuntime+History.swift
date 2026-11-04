import Foundation

// MARK: - History

extension CaptureRuntime {
    /// Replaces the loaded rows with the newest page, for a surface that opens
    /// at the top of the feed or for the Newest action.
    public func reloadHistory() async {
        guard started, let store, !state.historyJumpInFlight else { return }
        closeTrackHistory()
        state.pendingHistoryJump = nil
        state.historyJumpNotice = nil
        state.historyHasNewer = false
        historyWindowStart = nil
        await loadFirstPage(from: store, generation: startGeneration)
        await reloadDeliveryState()
    }

    /// Appends the next page. The store's cursor makes this keyset paging, so a
    /// listen inserted between two requests cannot duplicate or skip a row.
    public func loadMoreHistory() async {
        guard started, state.historyHasMore, !historyLoading, let store,
              let cursor = state.listens.last.flatMap(ListenCursor.init)
        else { return }

        let request = historyGeneration
        historyLoading = true
        defer {
            // A newer request already released the flag; clearing it here
            // would drop that load's claim.
            if historyGeneration == request {
                historyLoading = false
            }
        }

        do {
            let page = try await fillingKnownArtwork(
                store.page(limit: historyPageSize, before: cursor),
            )
            guard isCurrentHistoryRequest(request, startGeneration: startGeneration) else { return }
            var known = Set(state.listens.compactMap(\.id))
            for listen in page where listen.id.map({ !known.contains($0) }) ?? false {
                known.insert(listen.id ?? 0)
                state.listens.append(listen)
            }
            state.historyHasMore = await hasOlderListen(
                in: state.listens,
                total: state.historyCount,
                store: store,
            )
            clearHistoryFailure()
            await refreshDayCounts(from: store, request: request, generation: startGeneration)
            await loadStoredArtwork(for: page)
            await loadFeedback(for: page.map(\.processed.identity))
            await reloadDeliveryState()
        } catch {
            guard isCurrentHistoryRequest(request, startGeneration: startGeneration) else { return }
            recordHistoryFailure(error)
        }
    }

    /// Prepends the immediately newer page to a jumped window. The anchored
    /// rows are never re-read or reordered, so a timestamp tie at the page
    /// boundary is split exactly once by the keyset. Reaching the newest row
    /// returns History to its normal top mode.
    public func loadNewerHistory() async {
        guard started, state.historyHasNewer, !historyLoading, let store,
              let navigation = store as? any HistoryNavigationStore,
              let newest = state.listens.first, let cursor = ListenCursor(newest)
        else { return }

        let request = historyGeneration
        historyLoading = true
        defer {
            if historyGeneration == request {
                historyLoading = false
            }
        }

        do {
            let newer = try await fillingKnownArtwork(
                navigation.page(limit: historyPageSize, after: cursor),
            )
            guard isCurrentHistoryRequest(request, startGeneration: startGeneration) else { return }
            var known = Set(state.listens.compactMap(\.id))
            let added = newer.filter { listen in
                guard let id = listen.id else { return false }
                return !known.contains(id)
            }
            guard !added.isEmpty else {
                // Nothing newer exists; finish the jump instead of leaving a
                // button that cannot move.
                historyWindowStart = nil
                state.historyHasNewer = false
                state.historyJumpNotice = nil
                return
            }
            state.listens = added + state.listens
            for listen in added {
                if let id = listen.id {
                    known.insert(id)
                }
            }
            let hasNewer = await hasNewerListen(in: state.listens, store: store)
            let hasOlder = await hasOlderListen(
                in: state.listens,
                total: state.historyCount,
                store: store,
            )
            guard isCurrentHistoryRequest(request, startGeneration: startGeneration) else { return }
            state.historyHasNewer = hasNewer
            state.historyHasMore = hasOlder
            state.historyJumpNotice = hasNewer ? state.historyJumpNotice : nil
            historyWindowStart = hasNewer ? state.listens.first.flatMap(ListenCursor.init) : nil
            clearHistoryFailure()
            await refreshDayCounts(from: store, request: request, generation: startGeneration)
            await loadStoredArtwork(for: added)
            await loadFeedback(for: added.map(\.processed.identity))
            await reloadDeliveryState()
        } catch {
            guard isCurrentHistoryRequest(request, startGeneration: startGeneration) else { return }
            recordHistoryFailure(error)
        }
    }

    /// Applies the one-shot jump queued by Settings. A runtime that is not
    /// started leaves the request pending, so a refused presentation is
    /// retried on the next open rather than lost.
    public func applyPendingHistoryJump() async {
        guard started, let date = state.pendingHistoryJump else { return }
        await jumpHistory(to: date)
    }

    public func jumpHistory(to date: Date) async {
        guard started, let store else { return }
        state.historyJumpInFlight = true
        defer { state.historyJumpInFlight = false }
        closeTrackHistory()
        guard let navigation = store as? any HistoryNavigationStore else {
            recordHistoryFailure(DatabaseError.unavailable("Date jumps are unavailable"))
            return
        }

        let request = nextHistoryRequest()
        do {
            let position = try await navigation.historyPosition(at: date)
            let listens: [Listen] = if let cursor = position.cursor {
                try await navigation.page(limit: historyPageSize, endingAt: cursor)
            } else {
                try await store.page(limit: historyPageSize, before: nil)
            }
            let total = try await store.count()
            let hasNewer = await hasNewerListen(in: listens, store: store)
            let hasOlder = await hasOlderListen(in: listens, total: total, store: store)
            let dayCount = await count(on: date, store: store)
            guard isCurrentHistoryRequest(request, startGeneration: startGeneration) else { return }

            historyWindowStart = hasNewer ? listens.first.flatMap(ListenCursor.init) : nil
            guard applyHistoryPage(
                listens,
                total: total,
                request: request,
                generation: startGeneration,
                hasMore: hasOlder,
            ) else { return }
            // Consume only after the jump has been applied. A failed read or a
            // presentation that loses its generation keeps the request for the
            // next open.
            state.consumeHistoryJump(date)
            state.historyHasNewer = hasNewer
            state.historyJumpNotice = jumpNotice(
                requestedAt: date,
                position: position,
                total: total,
                dayCount: dayCount,
            )
            await refreshDayCounts(from: store, request: request, generation: startGeneration)
            await loadStoredArtwork(for: listens)
            await loadFeedback(for: listens.map(\.processed.identity))
            await reloadDeliveryState()
        } catch {
            guard isCurrentHistoryRequest(request, startGeneration: startGeneration) else { return }
            recordHistoryFailure(error)
        }
    }

    func loadFirstPage(from store: any ListenStore, generation: Int) async {
        let request = nextHistoryRequest()
        historyWindowStart = nil
        state.historyHasNewer = false
        state.historyJumpNotice = nil
        do {
            let listens = try await store.page(limit: historyPageSize, before: nil)
            let total = try await store.count()
            let hasOlder = await hasOlderListen(in: listens, total: total, store: store)
            guard applyHistoryPage(
                listens,
                total: total,
                request: request,
                generation: generation,
                hasMore: hasOlder,
            ) else { return }
            await refreshDayCounts(from: store, request: request, generation: generation)
            await loadStoredArtwork(for: listens)
            await loadFeedback(for: listens.map(\.processed.identity))
        } catch {
            guard isCurrentHistoryRequest(request, startGeneration: generation) else { return }
            recordHistoryFailure(error)
        }
    }

    /// Reloads the rows the surface has already loaded. A captured listen can
    /// land mid-page, and the store's sort order is the only thing that decides
    /// where; replacing the window keeps the feed in start order without
    /// splicing a row in by hand.
    ///
    /// A jumped window reloads from its own newest row, so a listen captured
    /// while the user is browsing older history does not move the window. The
    /// runtime is the store's only writer, so every store change routes
    /// through `persist` and this reload. A second writer would need the store
    /// to publish changes.
    func reloadVisibleHistory(in store: any ListenStore) async {
        let limit = max(state.listens.count, historyPageSize)
        let request = nextHistoryRequest()
        do {
            let listens: [Listen] = if let start = historyWindowStart,
                                       let navigation = store as? any HistoryNavigationStore {
                try await navigation.page(limit: limit, endingAt: start)
            } else {
                try await store.page(limit: limit, before: nil)
            }
            let total = try await store.count()
            let hasOlder = await hasOlderListen(in: listens, total: total, store: store)
            let hasNewer = historyWindowStart == nil
                ? false
                : await hasNewerListen(in: listens, store: store)
            guard applyHistoryPage(
                listens,
                total: total,
                request: request,
                generation: startGeneration,
                needsScrobbling: true,
                hasMore: hasOlder,
            ) else { return }
            historyWindowStart = hasNewer ? listens.first.flatMap(ListenCursor.init) : nil
            state.historyHasNewer = hasNewer
            await refreshDayCounts(
                from: store,
                request: request,
                generation: startGeneration,
                needsScrobbling: true,
            )
            await loadStoredArtwork(for: listens)
            await loadFeedback(for: listens.map(\.processed.identity))
        } catch {
            guard isCurrentHistoryRequest(
                request,
                startGeneration: startGeneration,
                needsScrobbling: true,
            ) else { return }
            recordHistoryFailure(error)
        }
    }

    /// Clears every transient History navigation state. Called when the
    /// takeover closes, the History section is left, or the runtime stops:
    /// reopening starts at the newest feed. A pending one-shot jump is kept
    /// until it is applied or the runtime stops, so a refused or interrupted
    /// presentation is retried on the next open instead of being lost.
    public func resetHistoryNavigation() {
        historyGeneration += 1
        historyLoading = false
        historyWindowStart = nil
        state.historyHasNewer = false
        state.historyJumpNotice = nil
        state.historyJumpInFlight = false
        state.historySettingsUnavailable = false
        closeTrackHistory()
    }

    // MARK: - Helpers

    private func applyHistoryPage(
        _ listens: [Listen],
        total: Int,
        request: Int,
        generation: Int,
        needsScrobbling: Bool = false,
        hasMore: Bool = false,
    ) -> Bool {
        guard isCurrentHistoryRequest(
            request,
            startGeneration: generation,
            needsScrobbling: needsScrobbling,
        ) else { return false }
        state.listens = fillingKnownArtwork(listens)
        state.historyCount = total
        state.historyHasMore = hasMore
        clearHistoryFailure()
        return true
    }

    /// Counts each loaded day across the whole store, not just the rows on the
    /// page. A count that cannot be read leaves the day on its loaded count.
    private func refreshDayCounts(
        from store: any ListenStore,
        request: Int,
        generation: Int,
        needsScrobbling: Bool = false,
    ) async {
        let calendar = Calendar.current
        let days = HistoryFeed.days(from: state.listens, calendar: calendar).map(\.date)
        var counts: [Date: Int] = [:]
        for day in days {
            guard let end = calendar.date(byAdding: .day, value: 1, to: day) else { continue }
            if let count = try? await store.count(in: day ..< end) {
                counts[day] = count
            }
        }
        guard isCurrentHistoryRequest(
            request,
            startGeneration: generation,
            needsScrobbling: needsScrobbling,
        ) else { return }
        state.historyDayCounts = counts
    }

    private func hasOlderListen(
        in listens: [Listen],
        total: Int,
        store: any ListenStore,
    ) async -> Bool {
        guard let last = listens.last, let cursor = ListenCursor(last) else { return false }
        if let navigation = store as? any HistoryNavigationStore,
           let exists = try? await navigation.hasOlderListen(than: cursor) {
            return exists
        }
        return total > listens.count
    }

    private func hasNewerListen(
        in listens: [Listen],
        store: any ListenStore,
    ) async -> Bool {
        guard let first = listens.first, let cursor = ListenCursor(first),
              let navigation = store as? any HistoryNavigationStore,
              let exists = try? await navigation.hasNewerListen(than: cursor)
        else { return false }
        return exists
    }

    /// A history request is stale once its owner stops, a newer start takes
    /// over, another reload begins while it is suspended, or a capture reload
    /// loses the switch it belongs to.
    private func isCurrentHistoryRequest(
        _ request: Int,
        startGeneration: Int,
        needsScrobbling: Bool = false,
    ) -> Bool {
        started
            && startGeneration == self.startGeneration
            && request == historyGeneration
            && !Task.isCancelled
            && (!needsScrobbling || state.scrobblingEnabled)
    }

    private func nextHistoryRequest() -> Int {
        historyGeneration += 1
        // A reload supersedes any in-flight page request. Release its claim
        // so the next page can start instead of waiting on the stale one.
        historyLoading = false
        return historyGeneration
    }

    func recordHistoryFailure(_ error: Error) {
        let failure = CaptureFailure.history(error: error)
        state.historyFailure = failure
        state.failure = failure
    }

    func clearHistoryFailure() {
        state.historyFailure = nil
        if state.failure?.stage == .history {
            state.failure = nil
        }
    }
}
