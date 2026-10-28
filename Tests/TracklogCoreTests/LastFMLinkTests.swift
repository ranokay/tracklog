import Foundation
import Testing
@testable import TracklogCore

/// A scripted browser-link client. It records each request so a test can see
/// the poll actually happened.
actor ScriptedLinkClient: LastFMLinkClient {
    enum TokenAnswer: Sendable {
        case challenge(LastFMLinkChallenge)
        case failure(LastFMError)
    }

    enum SessionAnswer: Sendable {
        case session(LastFMSession)
        case failure(LastFMError)
    }

    private var tokenAnswers: [TokenAnswer]
    private var sessionAnswers: [SessionAnswer]
    private(set) var tokenRequests = 0
    private(set) var sessionRequests = 0

    init(
        tokenAnswers: [TokenAnswer] = [],
        sessionAnswers: [SessionAnswer] = [],
    ) {
        self.tokenAnswers = tokenAnswers
        self.sessionAnswers = sessionAnswers
    }

    func requestToken() async throws -> LastFMLinkChallenge {
        tokenRequests += 1
        guard !tokenAnswers.isEmpty else { throw LastFMError.transport }
        switch tokenAnswers.removeFirst() {
        case let .challenge(challenge): return challenge
        case let .failure(error): throw error
        }
    }

    func session(token _: String) async throws -> LastFMSession {
        sessionRequests += 1
        guard !sessionAnswers.isEmpty else { throw LastFMError.transport }
        switch sessionAnswers.removeFirst() {
        case let .session(session): return session
        case let .failure(error): throw error
        }
    }
}

@MainActor
private func waitForLinkPhase(
    _ model: LastFMLinkModel,
    timeout: Duration = .seconds(3),
    until: (LastFMLinkModel.Phase) -> Bool,
) async -> LastFMLinkModel.Phase {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    var phase = model.phase
    while !until(phase), clock.now < deadline {
        try? await Task.sleep(for: .milliseconds(5))
        phase = model.phase
    }
    return phase
}

@MainActor
private func waitForSessionRequests(
    _ client: ScriptedLinkClient,
    count: Int,
    timeout: Duration = .seconds(3),
) async -> Int {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    var requests = await client.sessionRequests
    while requests < count, clock.now < deadline {
        try? await Task.sleep(for: .milliseconds(5))
        requests = await client.sessionRequests
    }
    return requests
}

@Suite("Last.fm link")
@MainActor
struct LastFMLinkTests {
    private let base = Date(timeIntervalSince1970: 1_000_000)
    private let challenge = LastFMLinkChallenge(
        token: "request-token",
        authorizationURL: URL(string: "https://www.last.fm/api/auth/?api_key=xxxxxxxxxx&token=request-token")!,
    )
    private let session = LastFMSession(name: "listener", key: "session-key")

    private func connection(_ session: LastFMSession) -> Connection {
        Connection(
            id: 7,
            kind: .lastFM,
            endpoint: .lastFM,
            identity: session.name,
            createdAt: base,
        )
    }

    private func makeModel(
        client: ScriptedLinkClient,
        clock: FakeClock? = nil,
        opened: @escaping @MainActor (URL) -> Bool = { _ in true },
        completed: @escaping @MainActor (LastFMSession) -> Void = { _ in },
        onProblem: @escaping @MainActor (AppCredentialProblem) -> Void = { _ in },
    ) -> LastFMLinkModel {
        LastFMLinkModel(
            client: client,
            clock: clock ?? FakeClock(base),
            pollInterval: 3,
            openAuthorization: opened,
            complete: { [self] session in
                completed(session)
                return connection(session)
            },
            onAppCredentialProblem: onProblem,
        )
    }

    @Test func startsWithATokenAndOpensTheAuthorizationPage() async {
        let client = ScriptedLinkClient(tokenAnswers: [.challenge(challenge)])
        var opened: [URL] = []
        let model = makeModel(client: client, opened: { url in
            opened.append(url)
            return true
        })

        model.start()

        let phase = await waitForLinkPhase(model) {
            if case .waiting = $0 {
                return true
            }
            return false
        }
        #expect(phase == .waiting(challenge))
        #expect(opened == [challenge.authorizationURL])
        #expect(await client.tokenRequests == 1)
    }

    @Test func manualCheckLinksTheSessionAndHandsItToCompletion() async {
        let client = ScriptedLinkClient(
            tokenAnswers: [.challenge(challenge)],
            sessionAnswers: [.session(session)],
        )
        var completed: [LastFMSession] = []
        let model = makeModel(
            client: client,
            completed: { completed.append($0) },
        )

        model.start()
        _ = await waitForLinkPhase(model) { $0 == .waiting(challenge) }
        await model.checkNow()

        #expect(completed == [session])
        #expect(model.phase == .linked(connection(session)))
        #expect(await client.sessionRequests == 1)
    }

    @Test func pollsThroughAnUnauthorizedTokenAndThenLinks() async {
        let clock = FakeClock(base)
        let client = ScriptedLinkClient(
            tokenAnswers: [.challenge(challenge)],
            sessionAnswers: [
                .failure(.service(code: 14, message: "This token has not been authorized.")),
                .session(session),
            ],
        )
        let model = makeModel(client: client, clock: clock)

        model.start()
        _ = await waitForLinkPhase(model) { $0 == .waiting(challenge) }

        clock.advance(to: clock.now.addingTimeInterval(3))
        #expect(await waitForSessionRequests(client, count: 1) == 1)
        #expect(model.phase == .waiting(challenge))

        clock.advance(to: clock.now.addingTimeInterval(3))
        let phase = await waitForLinkPhase(model) {
            if case .linked = $0 {
                return true
            }
            return false
        }
        #expect(phase == .linked(connection(session)))
        #expect(await client.sessionRequests == 2)

        model.cancel()
    }

    @Test func aManualCheckExplainsThatAuthorizationIsStillPending() async {
        let client = ScriptedLinkClient(
            tokenAnswers: [.challenge(challenge)],
            sessionAnswers: [
                .failure(.service(code: 14, message: "This token has not been authorized.")),
            ],
        )
        let model = makeModel(client: client)

        model.start()
        _ = await waitForLinkPhase(model) { $0 == .waiting(challenge) }
        await model.checkNow()

        #expect(model.phase == .waiting(challenge))
        #expect(model.notice?.contains("not confirmed") == true)
        #expect(model.notice?.contains("Check again") == true)
        model.cancel()
    }

    @Test func leavingThePageCancelsThePoll() async {
        let clock = FakeClock(base)
        let client = ScriptedLinkClient(
            tokenAnswers: [.challenge(challenge)],
            sessionAnswers: [.session(session)],
        )
        let model = makeModel(client: client, clock: clock)

        model.start()
        _ = await waitForLinkPhase(model) { $0 == .waiting(challenge) }
        model.cancel()
        clock.advance(to: clock.now.addingTimeInterval(10))
        try? await Task.sleep(for: .milliseconds(50))

        #expect(model.phase == .cancelled)
        #expect(await client.sessionRequests == 0)
    }

    @Test func anAppCredentialFailureIsInlineAndReported() async {
        let client = ScriptedLinkClient(
            tokenAnswers: [.failure(.service(code: 10, message: "Invalid API key"))],
        )
        var reported: [AppCredentialProblem] = []
        let model = makeModel(client: client, onProblem: { reported.append($0) })

        model.start()

        let phase = await waitForLinkPhase(model) {
            if case .failed = $0 {
                return true
            }
            return false
        }
        guard case let .failed(message) = phase else {
            Issue.record("expected an inline failure")
            return
        }
        #expect(message.contains("API key"))
        #expect(reported == [.invalidKey])
    }

    @Test func aFailedSessionIsInlineAndNeverLinked() async {
        let client = ScriptedLinkClient(
            tokenAnswers: [.challenge(challenge)],
            sessionAnswers: [.failure(.service(code: 15, message: "This token has expired."))],
        )
        let model = makeModel(client: client)

        model.start()
        _ = await waitForLinkPhase(model) { $0 == .waiting(challenge) }
        await model.checkNow()

        #expect(model.phase != .linked(connection(session)))
        guard case let .failed(message) = model.phase else {
            Issue.record("expected an inline failure")
            return
        }
        #expect(message.contains("did not accept"))
    }

    @Test func startIsIdempotentWhileWaiting() async {
        let client = ScriptedLinkClient(tokenAnswers: [.challenge(challenge)])
        let model = makeModel(client: client)

        model.start()
        _ = await waitForLinkPhase(model) { $0 == .waiting(challenge) }
        model.start()
        try? await Task.sleep(for: .milliseconds(20))

        #expect(await client.tokenRequests == 1)
        model.cancel()
    }
}
