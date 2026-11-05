// swiftlint:disable file_length
import Foundation

/// The one loved-list read model. It reads only the current connection, keeps
/// no durable cache and never writes local history, deliveries or feedback.
@MainActor
// swiftlint:disable:next type_body_length
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
    private var retryDeadlineTask: Task<Void, Never>?
    private var nextCursor: LovedCursor?
    private var lastLoadedPage: Int?
    private var countedOmittedPages: Set<Int> = []
    private var scopeKey: String?
    private var displayedConnectionID: Int64?
    private var lastConnectionKey: String
    /// Bumped by a local row removal and by the start of a first-page read.
    /// A page that started before the bump is discarded, so a held reply can
    /// never restore an unloved row or overwrite a stepped-back cursor.
    private var mutationRevision = 0
    private var isLoadingFirstPage = false

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
        // The takeover can mount more than one preview of the same section.
        // Only the first mount reads; a later mount does not restart the list
        // and cannot wipe a notice or a freshly removed row.
        guard !isShowing else { return }
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
        guard isActive, isShowing, !isLoadingFirstPage, !state.lovedState.isLoadingMore,
              !isRetryBlocked, nextCursor != nil
        else { return }
        let revision = mutationRevision
        var next = state.lovedState
        next.isLoadingMore = true
        next.loadMoreFailure = nil
        state.lovedState = next
        let loadMoreTask = Task { [weak self] in
            guard let self else { return }
            await performLoadMore(revision: revision)
        }
        self.loadMoreTask = loadMoreTask
        await loadMoreTask.value
    }

    // MARK: - Feedback reconciliation

    /// Every successful feedback action on the displayed connection reconciles
    /// the list at the same seam, without holding the feedback chain open. A
    /// service-read row knows only title and artist, so a non-row action
    /// matches those fields; when several rows share them the first page is
    /// re-read rather than guessing which recording was unloved.
    public func feedbackSucceeded(
        _ action: FeedbackAction,
        track: Track,
        connections: [Connection],
        rowID: String? = nil,
    ) {
        guard isActive, isShowing, let displayedConnectionID,
              connections.contains(where: { $0.id == displayedConnectionID })
        else { return }
        switch action {
        case .unlove:
            let index: Int?
            if let rowID {
                index = state.lovedState.rows.firstIndex { $0.id == rowID }
            } else {
                let matches = state.lovedState.rows.indices.filter {
                    state.lovedState.rows[$0].matches(title: track.title, artist: track.artist)
                }
                if matches.count > 1 {
                    refreshInBackground()
                    return
                }
                index = matches.first
            }
            guard let index else { return }
            noteRemoval()
            var next = state.lovedState
            next.rows.remove(at: index)
            next.actionFailure = nil
            next.isLoadingMore = false
            next.hasMore = adjustedCursorAfterRemoval() != nil
            next.phase = settledPhase(rows: next.rows, omitted: next.omitted, hasMore: next.hasMore)
            state.lovedState = next
        case .love:
            refreshInBackground()
        case .hate:
            break
        }
    }

    private func refreshInBackground() {
        Task { [weak self] in
            guard let self else { return }
            await refresh()
        }
    }

    /// A row removal makes every reply already in flight obsolete. The stepped
    /// cursor is applied now; the held reply is discarded when it returns and
    /// can never restore the row.
    private func noteRemoval() {
        mutationRevision += 1
        loadMoreTask?.cancel()
        loadMoreTask = nil
        readTask?.cancel()
        readTask = nil
        isLoadingFirstPage = false
        state.lovedState.isLoadingMore = false
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
        mutationRevision += 1
        let revision = mutationRevision
        generation += 1
        let token = generation
        isLoadingFirstPage = true
        defer {
            if generation == token {
                isLoadingFirstPage = false
            }
        }
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
        next.actionFailure = previous.actionFailure
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
            revision: revision,
        ) else { return }
        switch prepared {
        case let .unavailable(message):
            applyUnavailable(message, connection: connection)
        case let .failed(failure):
            applyFirstPageFailure(failure, connection: connection, preserving: preserving)
        case let .ready(request):
            scopeKey = request.scopeKey
            displayedConnectionID = request.connection.id
            await readFirstPage(
                request,
                token: token,
                preserving: preserving,
                revision: revision,
            )
        }
    }

    private func readFirstPage(
        _ request: LovedRequest,
        token: Int,
        preserving: Bool,
        revision: Int,
    ) async {
        var cursor: LovedCursor? = request.client.firstCursor
        var rows: [LovedRow] = []
        var omitted = 0
        var nextCursor: LovedCursor?
        var lastPage: Int?
        var countedPages: Set<Int> = []
        var reads = 0

        while let pageCursor = cursor, reads < Self.maximumInitialReads {
            let outcome = await Self.readPage(
                request.client,
                connection: request.connection,
                credential: request.credential,
                cursor: pageCursor,
            )
            guard isCurrent(
                token: token,
                connectionKey: request.scopeKey,
                revision: revision,
            ) else { return }
            reads += 1
            switch outcome {
            case let .page(page):
                rows = Self.merged(rows, page.rows)
                if case let .page(number) = pageCursor {
                    countedPages.insert(number)
                    lastPage = number
                }
                omitted += page.omitted
                nextCursor = page.nextCursor
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
        // Only a published read replaces the counted pages. A discarded reply
        // must not change what a later load-more treats as already counted.
        countedOmittedPages = countedPages
        cancelRetryDeadline()
        var next = LovedViewState()
        next.sourceLabel = LovedCopy.sourceLabel(request.connection)
        next.rows = rows
        next.omitted = omitted
        next.hasMore = nextCursor != nil
        next.phase = settledPhase(rows: rows, omitted: omitted, hasMore: nextCursor != nil)
        next.actionFailure = state.lovedState.actionFailure
        applyEligibility(to: &next, connection: request.connection, failure: nil)
        state.lovedState = next
    }

    // MARK: - Load more

    private func performLoadMore(revision: Int) async {
        guard revision == mutationRevision,
              let cursor = nextCursor,
              let connection = state.currentConnection
        else { return }
        let token = generation
        let connectionKey = Self.connectionKey(connection)
        guard scopeKey == connectionKey else { return }

        let prepared = await prepare(connection: connection)
        guard isCurrent(
            token: token,
            connectionKey: connectionKey,
            revision: revision,
        ) else { return }
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
            guard isCurrent(
                token: token,
                connectionKey: request.scopeKey,
                revision: revision,
            ) else { return }
            applyLoadMore(outcome, request: request, cursor: cursor, revision: revision)
        }
    }

    private func applyLoadMore(
        _ outcome: ReadOutcome,
        request: LovedRequest,
        cursor: LovedCursor,
        revision: Int,
    ) {
        guard revision == mutationRevision else { return }
        switch outcome {
        case let .page(page):
            var next = state.lovedState
            next.rows = Self.merged(next.rows, page.rows)
            if case let .page(number) = cursor {
                if !countedOmittedPages.contains(number) {
                    next.omitted += page.omitted
                    countedOmittedPages.insert(number)
                }
            } else {
                next.omitted += page.omitted
            }
            next.isLoadingMore = false
            next.loadMoreFailure = nil
            next.retryNotBefore = nil
            nextCursor = page.nextCursor
            next.hasMore = page.nextCursor != nil
            if case let .page(number) = cursor {
                lastLoadedPage = number
            }
            next.phase = settledPhase(
                rows: next.rows,
                omitted: next.omitted,
                hasMore: next.hasMore,
            )
            applyEligibility(to: &next, connection: request.connection, failure: nil)
            state.lovedState = next
            cancelRetryDeadline()
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
        scheduleRetryDeadline()
    }

    // MARK: - Publication

    private func applyUnavailable(_ message: String, connection: Connection?) {
        cancelRetryDeadline()
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
        scheduleRetryDeadline()
    }

    private func settledPhase(
        rows: [LovedRow],
        omitted: Int,
        hasMore: Bool,
    ) -> LovedPhase {
        if !rows.isEmpty {
            return .ready
        }
        if omitted > 0 {
            return .metadataUnavailable
        }
        if hasMore {
            // More pages exist even though this window named nothing (for
            // example, the first pages were all empty). Never call that an
            // empty account.
            return .ready
        }
        return .empty
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
            return .failed(.needsSignIn(.rejected))
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

    private func scheduleRetryDeadline() {
        retryDeadlineTask?.cancel()
        retryDeadlineTask = nil
        guard let deadline = state.lovedState.retryNotBefore else { return }
        retryDeadlineTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await clock.sleep(until: deadline)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            retryDeadlineReached(deadline)
        }
    }

    private func cancelRetryDeadline() {
        retryDeadlineTask?.cancel()
        retryDeadlineTask = nil
    }

    /// The hint has elapsed. Clear the wall, restore the action and let the
    /// view offer a retry without reopening the section.
    private func retryDeadlineReached(_ deadline: Date) {
        guard isActive, isShowing, state.lovedState.retryNotBefore == deadline else { return }
        var next = state.lovedState
        next.retryNotBefore = nil
        let failure: LovedFailure? = if case let .failed(value) = next.phase {
            value
        } else {
            next.refreshFailure ?? next.loadMoreFailure
        }
        var eligibilityFailure = failure
        if let failure, case .rateLimited = failure {
            eligibilityFailure = nil
        }
        applyEligibility(
            to: &next,
            connection: state.currentConnection,
            failure: eligibilityFailure,
        )
        state.lovedState = next
        retryDeadlineTask = nil
    }

    /// After a removal the row that shifted across the page boundary must not
    /// be skipped. ListenBrainz steps the offset back by the removed row;
    /// page-based services re-read the last loaded page and deduplicate. A nil
    /// cursor means the final page was already read: there is no next page to
    /// invent.
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
            break
        }
        return nextCursor
    }

    private func clearReadCursor() {
        nextCursor = nil
        lastLoadedPage = nil
        countedOmittedPages.removeAll()
        scopeKey = nil
    }

    private func cancelWork() {
        readTask?.cancel()
        readTask = nil
        loadMoreTask?.cancel()
        loadMoreTask = nil
        cancelRetryDeadline()
        isLoadingFirstPage = false
    }

    private func isCurrent(token: Int, connectionKey: String) -> Bool {
        token == generation
            && isActive
            && isShowing
            && Self.connectionKey(state.currentConnection) == connectionKey
    }

    private func isCurrent(token: Int, connectionKey: String, revision: Int) -> Bool {
        revision == mutationRevision && isCurrent(token: token, connectionKey: connectionKey)
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
