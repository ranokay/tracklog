// swiftlint:disable file_length
import Foundation

/// The one Last.fm catalogue read model the palette reads. It never touches
/// the store and never caches an answer: every settled query is a new read.
@MainActor
public final class CatalogueSearchReadModel {
    public nonisolated static let debounce: TimeInterval = 0.3
    public nonisolated static let minimumQueryLength = 2
    public nonisolated static let resultsPerGroup = 10
    public nonisolated static let visibleRowLimit = 5
    public nonisolated static let lovedPagesPerQuery = 5
    public nonisolated static let lovedPageSize = 200
    public nonisolated static let defaultTimeout: TimeInterval = 15

    private let state: TracklogAppState
    private let clock: any Clock
    private let client: any CatalogueSearching
    private let timeout: TimeInterval

    private var isActive = false
    private var isSessionOpen = false
    private var generation = 0
    private var debounceTask: Task<Void, Never>?
    private var groupTasks: [Task<Void, Never>] = []
    private var completionTask: Task<Void, Never>?

    public init(
        state: TracklogAppState,
        clock: any Clock,
        client: any CatalogueSearching,
        timeout: TimeInterval = CatalogueSearchReadModel.defaultTimeout,
    ) {
        self.state = state
        self.clock = clock
        self.client = client
        self.timeout = timeout
    }

    // MARK: - Lifecycle

    public func activate() {
        isActive = true
    }

    public func deactivate() {
        isActive = false
        closeSession()
    }

    /// A fresh palette open. Nothing survives from the previous session.
    public func beginSession() {
        guard isActive else { return }
        isSessionOpen = true
        cancelWork()
        generation += 1
        state.catalogueSearch = CatalogueSearchState()
    }

    /// The palette closed or the droplet deactivated. Every owned task stops
    /// and no answer can land afterwards.
    public func endSession() {
        closeSession()
    }

    public func updateQuery(_ text: String) {
        guard isActive, isSessionOpen else { return }
        cancelWork()
        generation += 1
        let token = generation
        state.catalogueSearch = CatalogueSearchState()
        state.catalogueSearch.query = text

        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= Self.minimumQueryLength else { return }

        state.catalogueSearch.isWaiting = true
        let clock = clock
        debounceTask = Task { @MainActor [weak self] in
            do {
                try await clock.sleep(until: clock.now.addingTimeInterval(Self.debounce))
            } catch {
                return
            }
            guard !Task.isCancelled,
                  let self,
                  isActive,
                  isSessionOpen,
                  generation == token
            else { return }
            start(query: query, token: token)
        }
    }

    /// A group's Try again. The query is already past the length gate, so the
    /// debounce is not repeated.
    public func retry() {
        guard isActive, isSessionOpen else { return }
        let query = state.catalogueSearch.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= Self.minimumQueryLength else { return }
        cancelWork()
        generation += 1
        start(query: query, token: generation)
    }

    /// The current connection changed while the palette is open. The loved
    /// group is account-scoped, so the whole query is read again; the account
    /// check in each answer's generation keeps the old rows from landing.
    public func connectionsChanged() {
        guard isActive, isSessionOpen else { return }
        let search = state.catalogueSearch
        guard search.isWaiting || search.isSearching || search.hasSearched else { return }
        let query = search.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= Self.minimumQueryLength else { return }
        cancelWork()
        generation += 1
        start(query: query, token: generation)
    }

    // MARK: - Reading

    private func start(query: String, token: Int) {
        var search = state.catalogueSearch
        search.isWaiting = false
        search.isSearching = true
        search.hasSearched = true
        for index in search.groups.indices {
            search.groups[index].phase = .loading
            search.groups[index].rows = []
            search.groups[index].detail = nil
        }
        state.catalogueSearch = search

        let connection = state.currentConnection
        let client = client
        let timeout = timeout
        groupTasks = CatalogueGroupKind.allCases.map { kind in
            Task { @MainActor [weak self] in
                let read = await Self.read(
                    kind: kind,
                    client: client,
                    connection: connection,
                    query: query,
                    timeout: timeout,
                )
                guard let self, !Task.isCancelled else { return }
                apply(read, kind: kind, token: token)
            }
        }
        let tasks = groupTasks
        completionTask = Task { @MainActor [weak self] in
            for task in tasks {
                _ = await task.value
            }
            guard let self, !Task.isCancelled else { return }
            finish(token: token)
        }
    }

    private func apply(_ read: GroupRead, kind: CatalogueGroupKind, token: Int) {
        guard token == generation,
              isActive,
              isSessionOpen,
              let index = state.catalogueSearch.groups.firstIndex(where: { $0.kind == kind })
        else { return }
        var search = state.catalogueSearch
        switch read {
        case let .rows(rows, detail):
            search.groups[index].phase = .ready
            search.groups[index].rows = rows
            search.groups[index].detail = detail
        case let .empty(detail):
            search.groups[index].phase = .empty
            search.groups[index].rows = []
            search.groups[index].detail = detail
        case let .unavailable(detail):
            search.groups[index].phase = .unavailable
            search.groups[index].rows = []
            search.groups[index].detail = detail
        case let .failed(failure):
            search.groups[index].phase = .failed(failure)
            search.groups[index].rows = []
            search.groups[index].detail = nil
        }
        state.catalogueSearch = search
    }

    private func finish(token: Int) {
        guard token == generation, isActive, isSessionOpen else { return }
        var search = state.catalogueSearch
        search.isSearching = false
        state.catalogueSearch = search
    }

    private func closeSession() {
        isSessionOpen = false
        cancelWork()
        generation += 1
        state.catalogueSearch = CatalogueSearchState()
    }

    private func cancelWork() {
        debounceTask?.cancel()
        debounceTask = nil
        for task in groupTasks {
            task.cancel()
        }
        groupTasks = []
        completionTask?.cancel()
        completionTask = nil
    }
}

// MARK: - Group reads

private enum GroupRead: Sendable {
    case rows([CatalogueRow], detail: String?)
    case empty(detail: String?)
    case unavailable(String)
    case failed(CatalogueSearchFailure)
}

private enum TimedResult<Value: Sendable>: Sendable {
    case value(Value)
    case failure(CatalogueSearchFailure)
    case timeout
    case cancelled

    var result: Result<Value, CatalogueSearchFailure> {
        switch self {
        case let .value(value): .success(value)
        case let .failure(failure): .failure(failure)
        case .timeout: .failure(.timedOut)
        case .cancelled: .failure(.offline)
        }
    }
}

/// A one-shot race between a read and its timeout. Unlike a task group, the
/// winner returns without waiting for the loser to notice cancellation, so a
/// request that ignores cancellation cannot hold the palette open past the
/// timeout.
private actor TimeoutRace<Value: Sendable> {
    private var result: TimedResult<Value>?
    private var waiter: CheckedContinuation<TimedResult<Value>, Never>?

    func finish(_ value: TimedResult<Value>) {
        guard result == nil else { return }
        result = value
        waiter?.resume(returning: value)
        waiter = nil
    }

    func wait() async -> TimedResult<Value> {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if let result {
                    continuation.resume(returning: result)
                } else {
                    waiter = continuation
                }
            }
        } onCancel: {
            Task { [weak self] in
                await self?.finish(.cancelled)
            }
        }
    }
}

private extension CatalogueSearchReadModel {
    nonisolated static func read(
        kind: CatalogueGroupKind,
        client: any CatalogueSearching,
        connection: Connection?,
        query: String,
        timeout: TimeInterval,
    ) async -> GroupRead {
        if kind == .loved {
            return await readLoved(
                client: client,
                connection: connection,
                query: query,
                timeout: timeout,
            )
        }
        let result = await timed(seconds: timeout) {
            try await client.search(kind, query: query, limit: resultsPerGroup)
        }
        switch result {
        case let .success(page):
            let rows = Array(unique(page.rows).prefix(resultsPerGroup))
            return rows.isEmpty ? .empty(detail: nil) : .rows(rows, detail: nil)
        case let .failure(failure):
            return .failed(failure)
        }
    }

    nonisolated static func readLoved(
        client: any CatalogueSearching,
        connection: Connection?,
        query: String,
        timeout: TimeInterval,
    ) async -> GroupRead {
        guard let connection else {
            return .unavailable(
                "Loved results need a current Last.fm connection. Connect Last.fm or choose it as the current connection in Charts.",
            )
        }
        guard connection.kind == .lastFM else {
            return .unavailable(
                "Loved results come from a Last.fm account. The current connection is "
                    + "\(connection.kind.displayName); choose a Last.fm connection in Charts.",
            )
        }
        let account = connection.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = account.isEmpty ? connection.identity : account

        let result = await timed(seconds: timeout) { () -> (rows: [CatalogueRow], capped: Bool) in
            var matches: [CatalogueRow] = []
            var pagesRead = 0
            var hasMore = false
            while pagesRead < lovedPagesPerQuery {
                let read = try await client.lovedTracks(
                    account: connection.identity,
                    page: pagesRead + 1,
                    limit: lovedPageSize,
                )
                pagesRead += 1
                matches.append(contentsOf: read.rows.filter { matchesQuery($0, query: query) })
                matches = unique(matches)
                hasMore = read.hasMore
                if !hasMore || matches.count >= resultsPerGroup {
                    break
                }
            }
            return (
                Array(matches.prefix(resultsPerGroup)),
                hasMore && pagesRead == lovedPagesPerQuery,
            )
        }

        switch result {
        case let .success(value):
            let detail = value.capped
                ? "Loved by \(label) · first 1,000 checked"
                : "Loved by \(label)"
            if value.rows.isEmpty {
                return .empty(detail: detail)
            }
            return .rows(value.rows, detail: detail)
        case let .failure(failure):
            return .failed(failure)
        }
    }

    nonisolated static func unique(_ rows: [CatalogueRow]) -> [CatalogueRow] {
        var seen: Set<String> = []
        return rows.filter { seen.insert($0.id).inserted }
    }

    nonisolated static func matchesQuery(_ row: CatalogueRow, query: String) -> Bool {
        let haystack = "\(row.subtitle) \(row.title)"
        return haystack.range(
            of: query,
            options: [.caseInsensitive, .diacriticInsensitive],
        ) != nil
    }

    nonisolated static func timed<Value: Sendable>(
        seconds: TimeInterval,
        _ operation: @escaping @Sendable () async throws -> Value,
    ) async -> Result<Value, CatalogueSearchFailure> {
        let race = TimeoutRace<Value>()
        let work = Task {
            do {
                try await race.finish(.value(operation()))
            } catch {
                await race.finish(.failure(failure(for: error)))
            }
        }
        let timer = Task {
            do {
                try await Task.sleep(for: .seconds(seconds))
            } catch {
                return
            }
            await race.finish(.timeout)
        }
        let first = await race.wait()
        work.cancel()
        timer.cancel()
        return first.result
    }

    nonisolated static func failure(for error: any Error) -> CatalogueSearchFailure {
        if let failure = error as? CatalogueSearchFailure {
            return failure
        }
        guard let failure = error as? ServiceFailure else {
            return .offline
        }
        switch failure {
        case let .appCredentialAuth(problem):
            return .appCredentials(problem)
        case let .rateLimited(retryAfter):
            return .rateLimited(retryAfter)
        case .retryable:
            return .offline
        case .auth:
            return .service("Last.fm did not accept the catalogue request.")
        case let .rejected(message):
            return .service(message ?? "Last.fm rejected the catalogue request.")
        }
    }
}

// swiftlint:enable file_length
