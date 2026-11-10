import Foundation
import Testing
@testable import TracklogCore

/// Every line the adapter's diagnostics sink receives during one read.
private final class AttemptLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    func append(_ line: String) {
        lock.withLock { stored.append(line) }
    }

    var lines: [String] {
        lock.withLock { stored }
    }
}

/// The parameters a Last.fm request carries: the form body for a POST, the
/// query for a GET.
private func sentParameters(_ request: HTTPRequest) -> [String: String] {
    guard request.method == .get else { return formParameters(request) }
    let items = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    return items.reduce(into: [:]) { $0[$1.name] = $1.value ?? "" }
}

/// The attempt a `track.getInfo` request is: its verb, and `-no-username`
/// when it carries no username. Nil for any other call.
private func attemptName(_ request: HTTPRequest) -> String? {
    let parameters = sentParameters(request)
    guard parameters["method"] == "track.getInfo" else { return nil }
    let verb = request.method == .get ? "get" : "post"
    return parameters["username"] == nil ? "\(verb)-no-username" : verb
}

/// A `track.getInfo` answer that Last.fm gives an empty object for.
private let emptyObjectAnswer = HTTPResponse(statusCode: 200, body: Data("{}".utf8))

/// Answers `{}` to every `track.getInfo` attempt except the one named
/// `answering`, which gets `entity`. `pause` slows each Last.fm call.
private func trackAnswers(
    _ answering: String?,
    with entity: HTTPResponse,
    pause: TimeInterval = 0,
) -> @Sendable (HTTPRequest) throws -> HTTPResponse {
    { request in
        if pause > 0 {
            Thread.sleep(forTimeInterval: pause)
        }
        guard let attempt = attemptName(request) else {
            return HTTPResponse(statusCode: 404, body: Data())
        }
        return attempt == answering ? entity : emptyObjectAnswer
    }
}

/// A track answer without the account's own play count, as an answer for a
/// request that carried no username.
private func anonymousTrackInfo() -> HTTPResponse {
    HTTPResponse(
        statusCode: 200,
        body: Data(
            #"""
            {"track":{"name":"Heart of Glass",
            "url":"https://www.last.fm/music/Blondie/_/Heart+of+Glass",
            "duration":"234000","listeners":"100","playcount":"200"}}
            """#.utf8,
        ),
    )
}

private func facts(_ service: EntityServiceSection?) -> [EntityFact] {
    if case let .facts(served) = service {
        return served.facts
    }
    return []
}

@Suite("Last.fm entity read attempts")
@MainActor
struct EntityReadAttemptCompositionTests {
    private func trackRequest() throws -> EntityRequest {
        try #require(EntityRequest.track(title: "Heart of Glass", artist: "Blondie"))
    }

    /// Seeds the local history, links the account under `identity`, opens the
    /// track page and waits for its service section to leave loading.
    private func openTrack(
        _ composition: EntityTestComposition,
        identity: String = "listener",
    ) async throws -> EntityServiceSection {
        try await seedEntityHistory(composition.store)
        _ = try await composition.runtime.linkVerified(
            kind: .lastFM,
            credential: "session",
            identity: ServiceIdentity(name: identity),
        )
        try await composition.runtime.openEntityDetail(trackRequest())
        #expect(await waitForEntityService(composition.state) { $0 != .loading })
        return try #require(composition.state.entityDetail?.service)
    }

    private func lastFMRequests(_ composition: EntityTestComposition) async -> [HTTPRequest] {
        await composition.transport.requests(toHost: "ws.audioscrobbler.com")
    }

    @Test func anEmptyPostIsRetriedAsAGetAndTheGetsEntityIsShown() async throws {
        let log = AttemptLog()
        let composition = try await entityComposition(
            entityDiagnostics: { log.append($0) },
            handler: trackAnswers("get", with: entityLastFMTrackInfo(userPlays: 9)),
        )

        let service = try await openTrack(composition)

        let sent = await lastFMRequests(composition)
        #expect(sent.map(\.method) == [.post, .get])
        #expect(sent.map { attemptName($0) ?? "" } == ["post", "get"])
        #expect(sent.allSatisfy { sentParameters($0)["username"] == "listener" })
        #expect(facts(service).contains { $0.label == "Your plays" && $0.value == "9" })
        #expect(log.lines.count == 2)
        #expect(log.lines[0].contains("variant=post") && log.lines[0].hasSuffix("rendered=no"))
        #expect(log.lines[1].contains("variant=get") && log.lines[1].hasSuffix("rendered=yes"))
    }

    @Test func theThirdAttemptWithoutAUsernameRendersWithoutYourPlays() async throws {
        let log = AttemptLog()
        let composition = try await entityComposition(
            entityDiagnostics: { log.append($0) },
            handler: trackAnswers("post-no-username", with: anonymousTrackInfo()),
        )

        let service = try await openTrack(composition)

        let sent = await lastFMRequests(composition)
        #expect(sent.map { attemptName($0) ?? "" } == ["post", "get", "post-no-username"])
        #expect(sent.map(\.method) == [.post, .get, .post])
        #expect(sent.last.map { sentParameters($0)["username"] == nil } == true)
        #expect(facts(service).contains { $0.label == "Listeners on Last.fm" })
        #expect(!facts(service).contains { $0.label == "Your plays" })
        #expect(log.lines.count == 3)
        #expect(log.lines.last?.contains("variant=post-no-username") == true)
        #expect(log.lines.last?.hasSuffix("rendered=yes") == true)
    }

    @Test func theLastAttemptWithoutAUsernameRendersWithoutYourPlays() async throws {
        let log = AttemptLog()
        let composition = try await entityComposition(
            entityDiagnostics: { log.append($0) },
            handler: trackAnswers("get-no-username", with: anonymousTrackInfo()),
        )

        let service = try await openTrack(composition)

        let sent = await lastFMRequests(composition)
        #expect(sent.map { attemptName($0) ?? "" } == ["post", "get", "post-no-username", "get-no-username"])
        #expect(sent.last.map { $0.method == .get && sentParameters($0)["username"] == nil } == true)
        #expect(!facts(service).contains { $0.label == "Your plays" })
        #expect(log.lines.count == 4)
        #expect(log.lines.last?.contains("variant=get-no-username") == true)
        #expect(log.lines.last?.hasSuffix("rendered=yes") == true)

        // Every attempt line, including the GET's, carries no value, key,
        // signature, username or URL from its request.
        let secrets = sent.map { request -> [String] in
            [
                request.url.absoluteString,
                sentParameters(request)["api_sig"] ?? "",
                sentParameters(request)["api_key"] ?? "",
                "api-key",
                "secret",
                "listener",
                "Heart of Glass",
                "Blondie",
                "https://",
                "api_key",
                "ws.audioscrobbler",
            ]
        }
        for line in log.lines {
            for values in secrets {
                for value in values where !value.isEmpty {
                    #expect(!line.contains(value), "An attempt line carries a protected value.")
                }
            }
        }
    }

    @Test func everyAttemptAnsweredEmptyLeavesThePageUnreadable() async throws {
        let log = AttemptLog()
        let composition = try await entityComposition(
            entityDiagnostics: { log.append($0) },
            handler: trackAnswers(nil, with: emptyObjectAnswer),
        )

        let service = try await openTrack(composition)

        #expect(service == .failed(.unreadable))
        let sent = await lastFMRequests(composition)
        #expect(sent.count == 4)
        #expect(log.lines.count == 4)
        #expect(log.lines.allSatisfy { $0.hasSuffix("rendered=no") })
    }

    @Test func withoutAUsernameAnEmptyPostIsRetriedOnceAsAGet() async throws {
        let log = AttemptLog()
        let composition = try await entityComposition(
            entityDiagnostics: { log.append($0) },
            handler: trackAnswers(nil, with: emptyObjectAnswer),
        )

        let service = try await openTrack(composition, identity: "   ")

        #expect(service == .failed(.unreadable))
        let sent = await lastFMRequests(composition)
        #expect(sent.map(\.method) == [.post, .get])
        #expect(sent.allSatisfy { sentParameters($0)["username"] == nil })
        #expect(log.lines.count == 2)
        #expect(log.lines.allSatisfy { $0.hasSuffix("rendered=no") })
    }

    @Test func aRefusedRetryStopsTheSequenceAndMapsAsItDoes() async throws {
        let log = AttemptLog()
        let composition = try await entityComposition(
            entityDiagnostics: { log.append($0) },
            handler: { request in
                if attemptName(request) == "get" {
                    return entityLastFMError(29, message: "Rate limit exceeded")
                }
                return emptyObjectAnswer
            },
        )

        let service = try await openTrack(composition)

        #expect(service == .failed(.rateLimited(retryAfter: nil)))
        let sent = await lastFMRequests(composition)
        #expect(sent.map { attemptName($0) ?? "" } == ["post", "get"])
        #expect(log.lines.count == 2)
        #expect(log.lines.last?.contains("refused=service-29") == true)
        #expect(log.lines.last?.hasSuffix("rendered=no") == true)
    }

    @Test func aNonEmptyAnswerSendsNoRetry() async throws {
        let log = AttemptLog()
        let composition = try await entityComposition(
            entityDiagnostics: { log.append($0) },
            handler: trackAnswers("post", with: entityLastFMTrackInfo(userPlays: 9)),
        )

        let service = try await openTrack(composition)

        #expect(facts(service).contains { $0.label == "Your plays" })
        let sent = await lastFMRequests(composition)
        #expect(sent.map(\.method) == [.post])
        #expect(log.lines.count == 1)
        #expect(log.lines.first?.hasSuffix("rendered=yes") == true)
    }

    @Test func theWholeSequenceFitsTheServiceBudget() async throws {
        // Each call takes 0.15 seconds and the page timeout is 0.3. Four calls
        // take 0.6 seconds, so the read only renders if its budget is four
        // times the page timeout.
        let composition = try await entityComposition(
            timeout: 0.3,
            handler: trackAnswers("get-no-username", with: anonymousTrackInfo(), pause: 0.15),
        )

        let service = try await openTrack(composition)

        #expect(facts(service).contains { $0.label == "Listeners on Last.fm" })
        let sent = await lastFMRequests(composition)
        #expect(sent.count == 4)
    }
}
