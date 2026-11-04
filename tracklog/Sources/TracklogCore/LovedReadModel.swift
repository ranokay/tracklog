// swiftlint:disable file_length type_body_length
import Foundation

/// The one loved-list read model. It reads only the current connection, keeps
/// no durable cache and never writes local history, deliveries or feedback.
@MainActor
public final class LovedReadModel {
    public nonisolated static let pageSize = 50
    /// A first page whose entries all lack metadata reads the next pages before
    /// it claims there is nothing to show.
    public nonisolated static let maximumInitialReads = 3

    private let state: TracklogAppState
    private let credentials: any CredentialStore
    private let clock: any Clock
    private let clients: [ServiceKind: any LovedServiceReading]
    private let supportsLove: @MainActor (ServiceKind) -> Bool

    private var isActive = false
    private var isShowing = false
    private var generation = 0
    private var readTask: Task<Void, Never>?
    private var loadMoreTask: Task<Void, Never>?
    private var nextCursor: LovedCursor?
    private var lastLoadedPage: Int?
    private var scopeKey: String?
    private var displayedConnectionID: Int64?
    private var lastConnectionKey: String

    public init(
        state: TracklogAppState,
        credentials: any CredentialStore,
        clock: any Clock,
        serviceClients: [any LovedServiceReading],
        supportsLove: @escaping @MainActor (ServiceKind) -> Bool,
    ) {
        self.state = state
        self.credentials = credentials
        self.clock = clock
        var byKind: [ServiceKind: any LovedServiceReading] = [:]
        for client in serviceClients {
            byKind[client.kind] = client
        }
        clients = byKind
        self.supportsLove = supportsLove
        lastConnectionKey = Self.connectionKey(state.currentConnection)
    }

    // MARK: - Lifecycle

    public func activate() {
        guard !isActive else { return }
        isActive = true
        lastConnectionKey = Self.connectionKey(state.currentConnection)
        state.lovedState = LovedViewState()
    }

    public func deactivate() {
        isActive = false
        isShowing = false
        generation += 1
        cancelWork()
        clearReadCursor()
        displayedConnectionID = nil
        state.lovedState = LovedViewState()
    }

    /// The Loved section became visible. Every show is a fresh read: nothing
    /// survives from the previous show.
    public func show() async {
        guard isActive else { return }
        isShowing = true
        lastConnectionKey = Self.connectionKey(state.currentConnection)
        await beginFirstPage(preservingRows: false)
    }

    public func hide() {
        guard isShowing else { return }
        isShowing = false
        generation += 1
        cancelWork()
        clearReadCursor()
        displayedConnectionID = nil
        state.lovedState = LovedViewState()
    }

    public func refresh() async {
        guard isActive, isShowing, !isRetryBlocked else { return }
        await beginFirstPage(preservingRows: !state.lovedState.rows.isEmpty)
    }

    public func dismissActionFailure() {
        guard state.lovedState.actionFailure != nil else { return }
        state.lovedState.actionFailure = nil
    }

    /// A row action was refused or unconfirmed by the row's own connection.
    /// The row stays and the notice names the service.
    public func rowActionFailed(_ row: LovedRow, service: String) {
        guard isActive, isShowing,
              state.lovedState.rows.contains(where: { $0.id == row.id })
        else { return }
        state.lovedState.actionFailure = LovedActionFailure(
            rowID: row.id,
            message: LovedCopy.actionFailure(title: row.title, service: service),
        )
    }

    /// The current connection or its identity changed. Rows from another
    /// account are dropped before the new read starts, so a saved or late
    /// answer can never be shown as the new account's.
    public func connectionsChanged() {
        guard isActive else { return }
        let key = Self.connectionKey(state.currentConnection)
        guard key != lastConnectionKey else { return }
        lastConnectionKey = key
        generation += 1
        cancelWork()
        clearReadCursor()
        displayedConnectionID = nil
        state.lovedState = LovedViewState()
        guard isShowing else { return }
        readTask = Task { [weak self] in
            guard let self else { return }
            await loadFirstPage(preservingRows: false)
        }
    }

    // MARK: - Paging

    public func loadMore() async {
        guard isActive, isShowing, !state.lovedState.isLoadingMore, !isRetryBlocked,
              nextCursor != nil
        else { return }
        var next = state.lovedState
        next.isLoadingMore = true
        next.loadMoreFailure = nil
        state.lovedState = next
        let loadMoreTask = Task { [weak self] in
            guard let self else { return }
            await performLoadMore()
        }
        self.loadMoreTask = loadMoreTask
        await loadMoreTask.value
    }

    // MARK: - Feedback reconciliation

    /// Every successful feedback action on the displayed connection reconciles
    /// the list at the same seam. Rows are matched by the identity the feedback
    /// store uses, so a strip heart and a local listen agree.
    public func feedbackSucceeded(
        _ action: FeedbackAction,
        track: Track,
        connections: [Connection],
    ) async {
        guard isActive, isShowing, let displayedConnectionID,
              connections.contains(where: { $0.id == displayedConnectionID })
        else { return }
        switch action {
        case .unlove:
            let identity = ListenMetadata(track).identity
            guard let index = state.lovedState.rows.firstIndex(where: {
                $0.trackIdentity == identity
            }) else { return }
            var next = state.lovedState
            next.rows.remove(at: index)
            next.actionFailure = nil
            next.hasMore = adjustedCursorAfterRemoval() != nil
            if next.rows.isEmpty {
                next.phase = .empty
            }
            state.lovedState = next
        case .love:
            await refresh()
        case .hate:
            break
        }
    }

    // MARK: - First page

    private func beginFirstPage(preservingRows: Bool) async {
        readTask?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            await loadFirstPage(preservingRows: preservingRows)
        }
        readTask = task
        await task.value
    }

    private func loadFirstPage(preservingRows: Bool) async {
        generation += 1
        let token = generation
        let connection = state.currentConnection
        let connectionKey = connection.map(Self.connectionKey)
        let previous = state.lovedState
        let preserving = preservingRows
            && !previous.rows.isEmpty
            && scopeKey == connectionKey

        var next = preserving ? previous : LovedViewState()
        next.sourceLabel = connection.map(LovedCopy.sourceLabel) ?? previous.sourceLabel
        next.isLoadingMore = false
        next.loadMoreFailure = nil
        if !preserving {
            next.phase = .loading
            next.rows = []
            next.omitted = 0
            next.hasMore = false
            next.canUnlove = false
            next.unloveUnavailableReason = nil
        }
        state.lovedState = next

        let prepared = await prepare(connection: connection)
        guard isCurrent(
            token: token,
            connectionKey: connectionKey ?? Self.connectionKey(nil),
        ) else { return }
        switch prepared {
        case let .unavailable(message):
            applyUnavailable(message, connection: connection)
        case let .failed(failure):
            applyFirstPageFailure(failure, connection: connection, preserving: preserving)
        case let .ready(request):
            scopeKey = request.scopeKey
            displayedConnectionID = request.connection.id
            await readFirstPage(request, token: token, preserving: preserving)
        }
    }

    private func readFirstPage(_ request: LovedRequest, token: Int, preserving: Bool) async {
        var cursor: LovedCursor? = request.client.firstCursor
        var rows: [LovedRow] = []
        var omitted = 0
        var nextCursor: LovedCursor?
        var lastPage: Int?
        var reads = 0

        while let pageCursor = cursor, reads < Self.maximumInitialReads {
            let outcome = await Self.readPage(
                request.client,
                connection: request.connection,
                credential: request.credential,
                cursor: pageCursor,
            )
            guard isCurrent(token: token, connectionKey: request.scopeKey) else { return }
            reads += 1
            switch outcome {
            case let .page(page):
                rows = Self.merged(rows, page.rows)
                omitted += page.omitted
                nextCursor = page.nextCursor
                if case let .page(number) = pageCursor {
                    lastPage = number
                }
                cursor = page.nextCursor
                if !rows.isEmpty || page.nextCursor == nil {
                    cursor = nil
                }
            case let .unavailable(message):
                applyUnavailable(message, connection: request.connection)
                return
            case let .failed(failure):
                applyFirstPageFailure(
                    failure,
                    connection: request.connection,
                    preserving: preserving,
                )
                return
            }
        }

        self.nextCursor = nextCursor
        lastLoadedPage = lastPage
        var next = LovedViewState()
        next.sourceLabel = LovedCopy.sourceLabel(request.connection)
        next.rows = rows
        next.omitted = omitted
        next.hasMore = nextCursor != nil
        next.phase = rows.isEmpty
            ? (omitted > 0 ? .metadataUnavailable : .empty)
            : .ready
        applyEligibility(to: &next, connection: request.connection, failure: nil)
        state.lovedState = next
    }

    // MARK: - Load more

    private func performLoadMore() async {
        guard let cursor = nextCursor,
              let connection = state.currentConnection
        else { return }
        let token = generation
        let connectionKey = Self.connectionKey(connection)
        guard scopeKey == connectionKey else { return }

        let prepared = await prepare(connection: connection)
        guard isCurrent(token: token, connectionKey: connectionKey) else { return }
        switch prepared {
        case let .unavailable(message):
            finishLoadMore(failure: .service(message), connection: connection)
        case let .failed(failure):
            finishLoadMore(failure: failure, connection: connection)
        case let .ready(request):
            let outcome = await Self.readPage(
                request.client,
                connection: request.connection,
                credential: request.credential,
                cursor: cursor,
            )
            guard isCurrent(token: token, connectionKey: request.scopeKey) else { return }
            applyLoadMore(outcome, request: request, cursor: cursor)
        }
    }

    private func applyLoadMore(
        _ outcome: ReadOutcome,
        request: LovedRequest,
        cursor: LovedCursor,
    ) {
        switch outcome {
        case let .page(page):
            var next = state.lovedState
            next.rows = Self.merged(next.rows, page.rows)
            next.omitted += page.omitted
            next.isLoadingMore = false
            next.loadMoreFailure = nil
            nextCursor = page.nextCursor
            next.hasMore = page.nextCursor != nil
            if case let .page(number) = cursor {
                lastLoadedPage = number
            }
            next.phase = next.rows.isEmpty
                ? (next.omitted > 0 ? .metadataUnavailable : .empty)
                : .ready
            applyEligibility(to: &next, connection: request.connection, failure: nil)
            state.lovedState = next
        case let .unavailable(message):
            finishLoadMore(failure: .service(message), connection: request.connection)
        case let .failed(failure):
            finishLoadMore(failure: failure, connection: request.connection)
        }
    }

    private func finishLoadMore(failure: LovedFailure, connection: Connection) {
        var next = state.lovedState
        next.isLoadingMore = false
        next.loadMoreFailure = failure
        if let deadline = deadline(for: failure) {
            next.retryNotBefore = deadline
        }
        applyEligibility(to: &next, connection: connection, failure: failure)
        state.lovedState = next
    }

    // MARK: - Publication

    private func applyUnavailable(_ message: String, connection: Connection?) {
        var next = LovedViewState()
        next.sourceLabel = connection.map(LovedCopy.sourceLabel)
        next.phase = .unavailable(message)
        next.retryNotBefore = nil
        next.canUnlove = false
        next.unloveUnavailableReason = nil
        state.lovedState = next
    }

    private func applyFirstPageFailure(
        _ failure: LovedFailure,
        connection: Connection?,
        preserving: Bool,
    ) {
        var next = state.lovedState
        if preserving, !next.rows.isEmpty {
            next.refreshFailure = failure
            next.retryNotBefore = deadline(for: failure)
            next.isLoadingMore = false
            next.loadMoreFailure = nil
        } else {
            next = LovedViewState()
            next.sourceLabel = connection.map(LovedCopy.sourceLabel)
            next.phase = .failed(failure)
            next.retryNotBefore = deadline(for: failure)
        }
        applyEligibility(to: &next, connection: connection, failure: failure)
        state.lovedState = next
    }

    private func applyEligibility(
        to next: inout LovedViewState,
        connection: Connection?,
        failure: LovedFailure?,
    ) {
        guard let connection else {
            next.canUnlove = false
            next.unloveUnavailableReason = nil
            return
        }
        let service = connection.kind.displayName
        let reason = failureEligibilityReason(failure, service: service)
            ?? connectionEligibilityReason(connection, service: service)
        next.canUnlove = reason == nil
        next.unloveUnavailableReason = reason
    }

    private func failureEligibilityReason(_ failure: LovedFailure?, service: String) -> String? {
        guard let failure else { return nil }
        if failure.isAuthentication {
            return LovedCopy.failureMessage(failure, service: service, retryAt: nil)
        }
        if case .rateLimited = failure {
            return LovedCopy.rateLimited(service: service)
        }
        return nil
    }

    private func connectionEligibilityReason(
        _ connection: Connection,
        service: String,
    ) -> String? {
        guard connection.isEnabled else {
            return LovedCopy.paused(service: service)
        }
        guard connection.authState == .signedIn else {
            return LovedCopy.signIn(service: service)
        }
        guard supportsLove(connection.kind) else {
            return LovedCopy.unsupportedLove(service: service)
        }
        return nil
    }

    // MARK: - Reading

    private enum PreparedRead {
        case ready(LovedRequest)
        case unavailable(String)
        case failed(LovedFailure)
    }

    private struct LovedRequest {
        let connection: Connection
        let client: any LovedServiceReading
        let credential: String
        let scopeKey: String
    }

    private enum ReadOutcome {
        case page(LovedServicePage)
        case unavailable(String)
        case failed(LovedFailure)
    }

    private func prepare(connection: Connection?) async -> PreparedRead {
        guard let connection else {
            return .unavailable(LovedCopy.noConnection)
        }
        guard let client = clients[connection.kind] else {
            return .unavailable(LovedCopy.unavailableForKind(connection.kind))
        }
        guard connection.authState == .signedIn, let id = connection.id else {
            return .failed(.needsSignIn(.signedOut))
        }
        let credential: String
        do {
            guard let stored = try await credentials.credential(forConnection: id),
                  !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                return .failed(.needsSignIn(.credentialMissing))
            }
            credential = stored
        } catch {
            return .failed(.needsSignIn(.credentialUnavailable))
        }
        return .ready(
            LovedRequest(
                connection: connection,
                client: client,
                credential: credential,
                scopeKey: Self.connectionKey(connection),
            ),
        )
    }

    private nonisolated static func readPage(
        _ client: any LovedServiceReading,
        connection: Connection,
        credential: String,
        cursor: LovedCursor,
    ) async -> ReadOutcome {
        do {
            let page = try await client.loved(
                connection: connection,
                credential: credential,
                cursor: cursor,
                limit: pageSize,
            )
            return .page(page)
        } catch {
            return failureOutcome(for: error, connection: connection)
        }
    }

    private nonisolated static func failureOutcome(
        for error: any Error,
        connection: Connection,
    ) -> ReadOutcome {
        if let unsupported = error as? LovedServiceError,
           case let .unsupported(message) = unsupported {
            return .unavailable(
                message ?? "This server does not provide loved tracks for that account.",
            )
        }
        guard let failure = error as? ServiceFailure else {
            return .failed(.offline)
        }
        switch failure {
        case .auth:
            return .failed(.needsSignIn(.signedOut))
        case let .appCredentialAuth(problem):
            return .failed(.appCredentials(problem))
        case let .rateLimited(retryAfter):
            return .failed(.rateLimited(retryAfter: retryAfter))
        case .retryable:
            return .failed(.offline)
        case let .rejected(message):
            return .failed(
                .service(
                    message ?? "\(connection.kind.displayName) rejected the loved-track read.",
                ),
            )
        }
    }

    // MARK: - Cursors

    private var isRetryBlocked: Bool {
        guard let deadline = state.lovedState.retryNotBefore else { return false }
        return deadline > clock.now
    }

    private func deadline(for failure: LovedFailure) -> Date? {
        guard case let .rateLimited(retryAfter) = failure,
              let retryAfter, retryAfter > 0
        else { return nil }
        return clock.now.addingTimeInterval(retryAfter)
    }

    /// After a removal the row that shifted across the page boundary must not
    /// be skipped. ListenBrainz steps the offset back by the removed row;
    /// page-based services re-read the last loaded page and deduplicate.
    @discardableResult
    private func adjustedCursorAfterRemoval() -> LovedCursor? {
        switch nextCursor {
        case let .offset(value):
            nextCursor = .offset(max(0, value - 1))
        case .page:
            if let lastLoadedPage {
                nextCursor = .page(lastLoadedPage)
            }
        case nil:
            if let lastLoadedPage {
                nextCursor = .page(lastLoadedPage)
            }
        }
        return nextCursor
    }

    private func clearReadCursor() {
        nextCursor = nil
        lastLoadedPage = nil
        scopeKey = nil
    }

    private func cancelWork() {
        readTask?.cancel()
        readTask = nil
        loadMoreTask?.cancel()
        loadMoreTask = nil
    }

    private func isCurrent(token: Int, connectionKey: String) -> Bool {
        token == generation
            && isActive
            && isShowing
            && Self.connectionKey(state.currentConnection) == connectionKey
    }

    private nonisolated static func merged(_ existing: [LovedRow], _ new: [LovedRow]) -> [LovedRow] {
        var seen = Set(existing.map(\.id))
        var rows = existing
        for row in new where seen.insert(row.id).inserted {
            rows.append(row)
        }
        return rows
    }

    private nonisolated static func connectionKey(_ connection: Connection?) -> String {
        guard let connection else { return "none" }
        return [
            String(connection.id ?? -1),
            connection.kind.rawValue,
            connection.endpoint.description,
            connection.identity,
            connection.authState.rawValue,
            connection.isEnabled ? "enabled" : "paused",
        ].joined(separator: "\u{1F}")
    }
}

// swiftlint:enable file_length type_body_length
