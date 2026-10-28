import Combine
import Foundation

/// The page model for the Last.fm browser link. It owns the pending token, the
/// poll and the cancel-on-leave rule; the view only renders its phase and
/// forwards the two buttons.
@MainActor
public final class LastFMLinkModel: ObservableObject {
    public enum Phase: Equatable, Sendable {
        case idle
        case starting
        case waiting(LastFMLinkChallenge)
        case linked(Connection)
        case failed(String)
        case cancelled
    }

    @Published public private(set) var phase: Phase = .idle
    /// A check is in flight. The phase stays `.waiting` so a manual check does
    /// not discard the token the poll needs.
    @Published public private(set) var isChecking = false
    /// Inline guidance, such as a pending authorization or a browser that
    /// could not be opened. Never a HUD event.
    @Published public private(set) var notice: String?

    private let client: any LastFMLinkClient
    private let clock: any Clock
    private let pollInterval: TimeInterval
    private let openAuthorization: @MainActor (URL) -> Bool
    private let complete: @MainActor (LastFMSession) async throws -> Connection
    private let onAppCredentialProblem: (@MainActor (AppCredentialProblem) -> Void)?
    private var task: Task<Void, Never>?
    /// The in-flight manual check. `cancel()` stops it as well as the poll.
    private var checkTask: Task<Void, Never>?
    /// Invalidates a late token, session or completion result after the page
    /// leaves.
    private var lifecycle = 0

    private static let browserOpenFailureNotice =
        "The browser could not be opened. Choose Open Last.fm again to retry."

    public init(
        client: any LastFMLinkClient,
        clock: any Clock,
        pollInterval: TimeInterval = 3,
        openAuthorization: @escaping @MainActor (URL) -> Bool = { _ in true },
        complete: @escaping @MainActor (LastFMSession) async throws -> Connection,
        onAppCredentialProblem: (@MainActor (AppCredentialProblem) -> Void)? = nil,
    ) {
        self.client = client
        self.clock = clock
        self.pollInterval = max(1, pollInterval)
        self.openAuthorization = openAuthorization
        self.complete = complete
        self.onAppCredentialProblem = onAppCredentialProblem
    }

    /// Requests a token and starts polling while the page stays open. Safe to
    /// call again after SwiftUI rebuilds the page view.
    public func start() {
        switch phase {
        case .idle, .cancelled, .failed: break
        case .starting, .waiting, .linked: return
        }

        lifecycle += 1
        let generation = lifecycle
        phase = .starting
        notice = nil
        task?.cancel()
        checkTask?.cancel()
        checkTask = nil
        task = Task { [weak self] in
            await self?.begin(generation: generation)
        }
    }

    /// The manual "Check again" beside the poll.
    public func checkNow() async {
        guard checkTask == nil, case let .waiting(challenge) = phase else { return }
        let generation = lifecycle
        let task = Task { [weak self] in
            guard let self else { return }
            await check(challenge, generation: generation, manual: true)
        }
        checkTask = task
        await task.value
        if checkTask == task {
            checkTask = nil
        }
    }

    /// Reopens the authorization page without asking for a new token.
    public func openAuthorizationPage() {
        guard case let .waiting(challenge) = phase else { return }
        if !openAuthorization(challenge.authorizationURL) {
            notice = Self.browserOpenFailureNotice
        }
    }

    /// Stops the link. A connection that already completed is kept; leaving the
    /// page must not unlink it.
    public func cancel() {
        lifecycle += 1
        task?.cancel()
        task = nil
        checkTask?.cancel()
        checkTask = nil
        isChecking = false
        notice = nil
        if case .linked = phase {
            return
        }
        phase = .cancelled
    }

    private func begin(generation: Int) async {
        do {
            let challenge = try await client.requestToken()
            guard isCurrent(generation) else { return }
            phase = .waiting(challenge)
            if !openAuthorization(challenge.authorizationURL) {
                notice = Self.browserOpenFailureNotice
            }
            await poll(challenge, generation: generation)
        } catch {
            guard isCurrent(generation) else { return }
            fail(error, generation: generation)
        }
    }

    private func poll(_ challenge: LastFMLinkChallenge, generation: Int) async {
        while isCurrent(generation) {
            do {
                try await clock.sleep(until: clock.now.addingTimeInterval(pollInterval))
            } catch {
                return
            }
            guard isCurrent(generation), case .waiting = phase else { return }
            await check(challenge, generation: generation, manual: false)
        }
    }

    private func check(
        _ challenge: LastFMLinkChallenge,
        generation: Int,
        manual: Bool,
    ) async {
        guard isCurrent(generation), !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        do {
            let session = try await client.session(token: challenge.token)
            guard isCurrent(generation) else { return }
            let connection = try await complete(session)
            guard isCurrent(generation) else { return }
            phase = .linked(connection)
            task?.cancel()
            task = nil
        } catch let error as LastFMError where error.isUnauthorizedToken {
            guard isCurrent(generation) else { return }
            if manual {
                notice = "Last.fm has not confirmed the sign-in yet. "
                    + "Authorize Tracklog in your browser, then choose Check again."
            }
        } catch {
            guard isCurrent(generation) else { return }
            fail(error, generation: generation)
        }
    }

    private func fail(_ error: any Error, generation: Int) {
        guard isCurrent(generation) else { return }
        let serviceFailure = (error as? LastFMError)?.serviceFailure ?? (error as? ServiceFailure)
        if let problem = serviceFailure?.appCredentialProblem {
            onAppCredentialProblem?(problem)
        }
        if let lastFM = error as? LastFMError {
            phase = .failed(lastFM.serviceFailure.errorDescription ?? "Last.fm sign-in failed.")
        } else {
            phase = .failed(error.localizedDescription)
        }
        task?.cancel()
        task = nil
    }

    private func isCurrent(_ generation: Int) -> Bool {
        generation == lifecycle && !Task.isCancelled
    }
}

public extension LastFMError {
    /// Code 14 is the expected answer while the listener has not authorized
    /// the token yet. The link page keeps polling instead of failing.
    var isUnauthorizedToken: Bool {
        if case let .service(code, _) = self {
            return code == 14
        }
        return false
    }
}
