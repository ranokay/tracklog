import Foundation

// MARK: - History

extension CaptureRuntime {
    /// Replaces the loaded rows with the newest page, for a surface that opens
    /// at the top of the feed.
    public func reloadHistory() async {
        guard started, let store else { return }
        await loadFirstPage(from: store, generation: startGeneration)
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
            let page = try await store.page(limit: historyPageSize, before: cursor)
            guard isCurrentHistoryRequest(request, startGeneration: startGeneration) else { return }
            var known = Set(state.listens.compactMap(\.id))
            for listen in page where listen.id.map({ !known.contains($0) }) ?? false {
                known.insert(listen.id ?? 0)
                state.listens.append(listen)
            }
            state.historyHasMore = page.count == historyPageSize
            clearHistoryFailure()
            await refreshDayCounts(from: store, request: request, generation: startGeneration)
        } catch {
            guard isCurrentHistoryRequest(request, startGeneration: startGeneration) else { return }
            recordHistoryFailure(error)
        }
    }

    func loadFirstPage(from store: any ListenStore, generation: Int) async {
        let request = nextHistoryRequest()
        do {
            let listens = try await store.page(limit: historyPageSize, before: nil)
            let total = try await store.count()
            guard applyHistoryPage(listens, total: total, request: request, generation: generation) else { return }
            await refreshDayCounts(from: store, request: request, generation: generation)
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
    /// The runtime is the store's only writer, so every store change routes
    /// through `persist` and this reload. A second writer would need the store
    /// to publish changes.
    ///
    /// The window stays page-sized: a new row at the top displaces the oldest
    /// loaded row, which sits below the viewport in a full page. The view
    /// anchors to a surviving row.
    func reloadVisibleHistory(in store: any ListenStore) async {
        let limit = max(state.listens.count, historyPageSize)
        let request = nextHistoryRequest()
        do {
            let listens = try await store.page(limit: limit, before: nil)
            let total = try await store.count()
            guard applyHistoryPage(
                listens,
                total: total,
                request: request,
                generation: startGeneration,
                needsScrobbling: true,
            ) else { return }
            await refreshDayCounts(
                from: store,
                request: request,
                generation: startGeneration,
                needsScrobbling: true,
            )
        } catch {
            guard isCurrentHistoryRequest(
                request,
                startGeneration: startGeneration,
                needsScrobbling: true,
            ) else { return }
            recordHistoryFailure(error)
        }
    }

    private func applyHistoryPage(
        _ listens: [Listen],
        total: Int,
        request: Int,
        generation: Int,
        needsScrobbling: Bool = false,
    ) -> Bool {
        guard isCurrentHistoryRequest(
            request,
            startGeneration: generation,
            needsScrobbling: needsScrobbling,
        ) else { return false }
        state.listens = listens
        state.historyCount = total
        state.historyHasMore = total > listens.count
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
