// swiftlint:disable file_length type_body_length
import Foundation
import Testing
@testable import TracklogCore

@Suite("Loved browsing", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct LovedBrowsingTests {
    private let base = Date(timeIntervalSince1970: 1_000_000)

    // MARK: - Last.fm

    @Test func lastFMReadsTheCurrentAccountsLovedPageEveryTime() async throws {
        let database = try TemporaryDatabase()
        let transport = LovedTransport { request in
            if lovedLastFMMethod(request) == "user.getlovedtracks" {
                return lovedLastFMResponse(
                    [
                        LovedLastFMRow("Example Track One", mbid: "mbid-one"),
                        LovedLastFMRow("Example Track Two"),
                    ],
                    page: 1,
                    totalPages: 1,
                )
            }
            return HTTPResponse(statusCode: 404, body: Data())
        }
        let (runtime, store) = try makeLovedRuntime(
            database: database,
            clock: FakeClock(base),
            transport: transport,
        )
        await runtime.start()
        _ = try await runtime.linkVerified(
            kind: .lastFM,
            credential: "session-key",
            identity: ServiceIdentity(name: "listener"),
        )
        await runtime.loved?.show()

        let state = runtime.state
        #expect(state.lovedState.phase == .ready)
        #expect(state.lovedState.rows.count == 2)
        #expect(state.lovedState.sourceLabel == "Last.fm · listener")
        #expect(state.lovedState.canUnlove)
        #expect(state.lovedState.rows[0].trackIdentity == ListenMetadata(
            Track(title: "Example Track One", artist: "Example Artist"),
        ).identity)

        let reads = await transport.requests { lovedLastFMMethod($0) == "user.getlovedtracks" }
        #expect(reads.count == 1)
        let parameters = try #require(reads.first.map(formParameters))
        #expect(parameters["user"] == "listener")
        #expect(parameters["page"] == "1")
        #expect(parameters["limit"] == "50")
        #expect(parameters["api_key"] == lastFMTestCredentials.apiKey)
        #expect(parameters["sk"] == nil)
        #expect(parameters["api_sig"] != nil)

        // A read is not a local history or feedback write.
        #expect(try await store.count() == 0)
        #expect(state.listens.isEmpty)
        #expect(state.feedbackByTrack.isEmpty)
        let identities = state.lovedState.rows.map(\.trackIdentity)
        #expect(try await store.feedback(for: identities).isEmpty)

        // No cache: leaving and reopening reads again.
        runtime.loved?.hide()
        await runtime.loved?.show()
        #expect(await transport.requestCount() == 2)
        #expect(state.lovedState.rows.count == 2)
    }

    @Test func libreFMReadsItsOwnGNUFMRoot() async throws {
        let database = try TemporaryDatabase()
        let transport = LovedTransport { request in
            if lovedLastFMMethod(request) == "user.getlovedtracks" {
                return lovedLastFMResponse(
                    [LovedLastFMRow("Example Track One", artist: "Example Artist")],
                    page: 1,
                    totalPages: 1,
                )
            }
            return HTTPResponse(statusCode: 404, body: Data())
        }
        let (runtime, _) = try makeLovedRuntime(
            database: database,
            clock: FakeClock(base),
            transport: transport,
        )
        await runtime.start()
        let root = try #require(ServiceEndpoint(normalizing: "https://music.example.org"))
        _ = try await runtime.linkVerified(
            kind: .libreFM,
            credential: "session-key",
            identity: ServiceIdentity(name: "libre-listener"),
            endpoint: root,
        )
        await runtime.loved?.show()

        #expect(runtime.state.lovedState.phase == .ready)
        let reads = await transport.requests { lovedLastFMMethod($0) == "user.getlovedtracks" }
        let read = try #require(reads.first)
        #expect(read.url.absoluteString == "https://music.example.org/2.0/")
        let parameters = formParameters(read)
        #expect(parameters["api_key"] == "0123456789abcdef0123456789abcdef")
        #expect(parameters["sk"] == nil)
        #expect(parameters["api_sig"] == nil)
        #expect(parameters["user"] == "libre-listener")
    }

    // MARK: - ListenBrainz

    @Test func listenBrainzReadsFeedbackByRawOffsetAndOmitsUnnamedRows() async throws {
        let database = try TemporaryDatabase()
        let transport = LovedTransport { request in
            guard let query = lovedFeedbackQuery(request) else {
                return HTTPResponse(statusCode: 404, body: Data())
            }
            if query.offset == 0 {
                return lovedListenBrainzResponse(
                    [
                        LovedListenBrainzItem(
                            title: "Example Track One",
                            mbid: "mbid-a",
                        ),
                        LovedListenBrainzItem(title: nil, artist: nil, album: nil, mbid: "mbid-unnamed"),
                        LovedListenBrainzItem(
                            title: "Example Track Two",
                            album: "Example Album",
                            msid: "msid-b",
                        ),
                    ],
                    totalCount: 5,
                )
            }
            return lovedListenBrainzResponse(
                [
                    LovedListenBrainzItem(title: "Example Track Three", mbid: "mbid-c"),
                    LovedListenBrainzItem(title: "Example Track One", mbid: "mbid-a"),
                ],
                totalCount: 5,
            )
        }
        let (runtime, _) = try makeLovedRuntime(
            database: database,
            clock: FakeClock(base),
            transport: transport,
        )
        await runtime.start()
        _ = try await runtime.linkVerified(
            kind: .listenBrainz,
            credential: "demo-token",
            identity: ServiceIdentity(name: "listener"),
        )
        await runtime.loved?.show()

        let state = runtime.state
        #expect(state.lovedState.phase == .ready)
        #expect(state.lovedState.rows.count == 2)
        #expect(state.lovedState.omitted == 1)
        #expect(state.lovedState.hasMore)
        #expect(state.lovedState.rows[0].reference == .mbid("mbid-a"))
        #expect(state.lovedState.rows[1].reference == .msid("msid-b"))

        let requests = await transport.requests { lovedFeedbackQuery($0) != nil }
        let first = try #require(requests.first)
        let components = try #require(URLComponents(url: first.url, resolvingAgainstBaseURL: false))
        #expect(components.path == "/1/feedback/user/listener/get-feedback")
        #expect(components.queryItems?.first { $0.name == "score" }?.value == "1")
        #expect(components.queryItems?.first { $0.name == "metadata" }?.value == "true")
        #expect(components.queryItems?.first { $0.name == "count" }?.value == "50")
        #expect(first.headers["Authorization"] == "Token demo-token")

        await runtime.loved?.loadMore()
        let more = await transport.requests { lovedFeedbackQuery($0) != nil }
        #expect(more.count == 2)
        #expect(lovedFeedbackQuery(more[1])?.offset == 3)
        #expect(state.lovedState.rows.count == 3)
        #expect(Set(state.lovedState.rows.map(\.id)).count == 3)
        #expect(!state.lovedState.hasMore)
    }

    @Test func listenBrainzOffsetAdvancesByRawRowsAndStepsBackAfterRemoval() async throws {
        let database = try TemporaryDatabase()
        let transport = LovedTransport { request in
            guard let query = lovedFeedbackQuery(request) else {
                return HTTPResponse(statusCode: 404, body: Data())
            }
            if query.offset == 0 {
                return lovedListenBrainzResponse(
                    [
                        LovedListenBrainzItem(title: "Example Track One", mbid: "mbid-a"),
                        LovedListenBrainzItem(title: nil, artist: nil, album: nil, mbid: "mbid-unnamed"),
                    ],
                    totalCount: 4,
                )
            }
            return lovedListenBrainzResponse(
                [
                    LovedListenBrainzItem(title: "Example Track Two", mbid: "mbid-b"),
                    LovedListenBrainzItem(title: "Example Track Three", mbid: "mbid-c"),
                ],
                totalCount: 4,
            )
        }
        let (runtime, _) = try makeLovedRuntime(
            database: database,
            clock: FakeClock(base),
            transport: transport,
        )
        await runtime.start()
        let connection = try await runtime.linkVerified(
            kind: .listenBrainz,
            credential: "demo-token",
            identity: ServiceIdentity(name: "listener"),
        )
        await runtime.loved?.show()

        let row = try #require(runtime.state.lovedState.rows.first)
        runtime.loved?.feedbackSucceeded(.unlove, track: row.track, connections: [connection])
        #expect(runtime.state.lovedState.rows.isEmpty)

        await runtime.loved?.loadMore()
        let more = await transport.requests { lovedFeedbackQuery($0) != nil }
        #expect(more.count == 2)
        #expect(lovedFeedbackQuery(more[1])?.offset == 1)
        #expect(runtime.state.lovedState.rows.count == 2)
    }

    // MARK: - Page-based paging

    @Test func pageBasedRemovalRereadsTheLastPageWithoutSkipping() async throws {
        let database = try TemporaryDatabase()
        let counter = LovedPageCounter()
        let transport = LovedTransport { request in
            guard lovedLastFMMethod(request) == "user.getlovedtracks",
                  let page = formParameters(request)["page"]
            else {
                return HTTPResponse(statusCode: 404, body: Data())
            }
            switch page {
            case "1":
                return lovedLastFMResponse(
                    [LovedLastFMRow("Example Track One"), LovedLastFMRow("Example Track Two")],
                    page: 1,
                    totalPages: 3,
                )
            case "2":
                let read = await counter.next(2)
                if read == 1 {
                    return lovedLastFMResponse(
                        [LovedLastFMRow("Example Track Three"), LovedLastFMRow("Example Track Four")],
                        page: 2,
                        totalPages: 3,
                    )
                }
                return lovedLastFMResponse(
                    [
                        LovedLastFMRow("Example Track Three"),
                        LovedLastFMRow("Example Track Four"),
                        LovedLastFMRow("Example Track Five"),
                    ],
                    page: 2,
                    totalPages: 3,
                )
            default:
                return lovedLastFMResponse(
                    [LovedLastFMRow("Example Track Six")],
                    page: 3,
                    totalPages: 3,
                )
            }
        }
        let (runtime, _) = try makeLovedRuntime(
            database: database,
            clock: FakeClock(base),
            transport: transport,
        )
        await runtime.start()
        let connection = try await runtime.linkVerified(
            kind: .lastFM,
            credential: "session-key",
            identity: ServiceIdentity(name: "listener"),
        )
        await runtime.loved?.show()
        await runtime.loved?.loadMore()
        #expect(runtime.state.lovedState.rows.count == 4)

        let removed = try #require(runtime.state.lovedState.rows.first)
        runtime.loved?.feedbackSucceeded(.unlove, track: removed.track, connections: [connection])
        #expect(runtime.state.lovedState.rows.count == 3)

        await runtime.loved?.loadMore()
        let reads = await transport.requests { lovedLastFMMethod($0) == "user.getlovedtracks" }
        let pages = reads.compactMap { formParameters($0)["page"] }
        #expect(pages.last == "2")
        #expect(runtime.state.lovedState.rows.contains { $0.title == "Example Track Five" })
        #expect(Set(runtime.state.lovedState.rows.map(\.id)).count == runtime.state.lovedState.rows.count)

        await runtime.loved?.loadMore()
        let after = await transport.requests { lovedLastFMMethod($0) == "user.getlovedtracks" }
        #expect(after.compactMap { formParameters($0)["page"] }.last == "3")
    }

    // MARK: - Feedback

    @Test func aSourceScopedReferenceNeverLeaksToAnotherListenBrainzConnection() async throws {
        let database = try TemporaryDatabase()
        let one = try #require(ServiceEndpoint(normalizing: "https://lb-one.example"))
        let two = try #require(ServiceEndpoint(normalizing: "https://lb-two.example"))
        let transport = LovedTransport { request in
            if lovedIsLookup(request) {
                return jsonResponse(["recording_mbid": "lookup-mbid"])
            }
            if lovedIsFeedbackPost(request) {
                return jsonResponse(["status": "ok"])
            }
            if lovedFeedbackQuery(request) != nil {
                return lovedListenBrainzResponse(
                    [LovedListenBrainzItem(title: "Example Track One", mbid: "row-mbid")],
                    totalCount: 1,
                )
            }
            return HTTPResponse(statusCode: 404, body: Data())
        }
        let clock = FakeClock(base)
        let (runtime, _) = try makeLovedRuntime(
            database: database,
            clock: clock,
            transport: transport,
        )
        await runtime.start()
        let first = try await runtime.linkVerified(
            kind: .listenBrainz,
            credential: "token-one",
            identity: ServiceIdentity(name: "listener-one"),
            endpoint: one,
        )
        _ = try await runtime.linkVerified(
            kind: .listenBrainz,
            credential: "token-two",
            identity: ServiceIdentity(name: "listener-two"),
            endpoint: two,
        )
        try await runtime.setCurrentConnection(first.id)

        await runtime.loved?.show()
        let row = try #require(runtime.state.lovedState.rows.first)
        let action = Task { await runtime.unloveLovedRow(row) }
        // The lookup records its spacing timestamp before the POST. Wait for
        // the lookup itself, then advance past any spacing it recorded.
        let spacing = await lovedWaitForRequests(transport, count: 3)
        #expect(spacing.count >= 3, "the spacing lookup is recorded")
        guard spacing.count >= 3 else { return }
        clock.advance(to: base.addingTimeInterval(2))
        let confirmed = await lovedAwait(action)
        #expect(confirmed != nil, "the unlove completes")
        guard let confirmed else { return }
        #expect(confirmed)
        #expect(runtime.state.lovedState.rows.isEmpty)

        let posts = await transport.requests { lovedIsFeedbackPost($0) }
        #expect(posts.count == 2)
        let onePost = try #require(posts.first { $0.url.host == "lb-one.example" })
        let twoPost = try #require(posts.first { $0.url.host == "lb-two.example" })
        #expect(lovedFeedbackReference(onePost) == "row-mbid")
        #expect(lovedFeedbackReference(twoPost) == "lookup-mbid")
        #expect(lovedFeedbackScore(onePost) == 0)
        #expect(lovedFeedbackScore(twoPost) == 0)
        let lookups = await transport.requests { lovedIsLookup($0) }
        #expect(lookups.count == 1)
        #expect(lookups.first?.url.host == "lb-two.example")
    }

    @Test func aPartialUnloveLeavesTheRowAndNamesTheFailure() async throws {
        let database = try TemporaryDatabase()
        let probe = HUDProbe()
        let transport = LovedTransport { request in
            if lovedLastFMMethod(request) == "user.getlovedtracks" {
                return lovedLastFMResponse(
                    [LovedLastFMRow("Example Track One")],
                    page: 1,
                    totalPages: 1,
                )
            }
            if lovedLastFMMethod(request) == "track.unlove" {
                return lovedLastFMError(11)
            }
            if lovedIsLookup(request) {
                return jsonResponse(["recording_mbid": "lookup-mbid"])
            }
            if lovedIsFeedbackPost(request) {
                return jsonResponse(["status": "ok"])
            }
            return HTTPResponse(statusCode: 404, body: Data())
        }
        let clock = FakeClock(base)
        let (runtime, store) = try makeLovedRuntime(
            database: database,
            clock: clock,
            transport: transport,
            hud: probe.session,
        )
        await runtime.start()
        _ = try await runtime.linkVerified(
            kind: .lastFM,
            credential: "session-key",
            identity: ServiceIdentity(name: "listener"),
        )
        _ = try await runtime.linkVerified(
            kind: .listenBrainz,
            credential: "demo-token",
            identity: ServiceIdentity(name: "lb-listener"),
        )
        try await runtime.setCurrentConnection(
            runtime.state.connections.first { $0.kind == .lastFM }?.id,
        )
        await runtime.loved?.show()
        let row = try #require(runtime.state.lovedState.rows.first)

        let action = Task { await runtime.unloveLovedRow(row) }
        // Wait for the lookup, not merely the Last.fm call: the lookup records
        // the spacing timestamp the ListenBrainz POST will wait on.
        let spacing = await lovedWaitForRequests(transport, count: 3)
        #expect(spacing.count >= 3, "the spacing lookup is recorded")
        guard spacing.count >= 3 else { return }
        clock.advance(to: base.addingTimeInterval(2))
        let confirmed = await lovedAwait(action)
        #expect(confirmed != nil, "the unlove completes")
        guard let confirmed else { return }
        #expect(confirmed == false)
        #expect(runtime.state.lovedState.rows.count == 1)
        runtime.loved?.rowActionFailed(row, service: "Last.fm")
        #expect(
            runtime.state.lovedState.actionFailure?.message
                == "Could not unlove “Example Track One” on Last.fm. The service did not confirm the change.",
        )
        #expect(probe.presentations.last?.spoken == "Unloved on ListenBrainz.")
        #expect(try await store.count() == 0)
    }

    @Test func theStripHeartRemovesAMatchingRowAndALoveRereads() async throws {
        let database = try TemporaryDatabase()
        let transport = LovedTransport { request in
            if lovedLastFMMethod(request) == "user.getlovedtracks" {
                return lovedLastFMResponse(
                    [LovedLastFMRow("Example Track One")],
                    page: 1,
                    totalPages: 1,
                )
            }
            if lovedLastFMMethod(request) == "track.love"
                || lovedLastFMMethod(request) == "track.unlove" {
                return lastFMEmptyResponse()
            }
            return HTTPResponse(statusCode: 404, body: Data())
        }
        let clock = FakeClock(base)
        let (runtime, store) = try makeLovedRuntime(
            database: database,
            clock: clock,
            transport: transport,
        )
        await runtime.start()
        _ = try await runtime.linkVerified(
            kind: .lastFM,
            credential: "session-key",
            identity: ServiceIdentity(name: "listener"),
        )
        await runtime.loved?.show()
        let track = Track(
            title: "Example Track One",
            artist: "Example Artist",
            album: "Example Album",
            albumArtist: "Example Album Artist",
        )
        let identity = ListenMetadata(track).identity
        try await store.setFeedback(.loved, for: identity, at: base)
        runtime.state.nowPlaying = MediaSample(
            track: track,
            elapsed: 10,
            playbackRate: 1,
            isPlaying: true,
        )

        await runtime.toggleLoveForCurrentTrack()
        #expect(runtime.state.lovedState.rows.isEmpty)
        #expect(runtime.state.feedbackByTrack[identity] == nil)
        #expect(try await store.feedback(for: [identity]).isEmpty)
        #expect(await transport.requests { lovedLastFMMethod($0) == "track.unlove" }.count == 1)
        let readsAfterUnlove = await transport.requests { lovedLastFMMethod($0) == "user.getlovedtracks" }
        #expect(readsAfterUnlove.count == 1)

        await runtime.toggleLoveForCurrentTrack()
        #expect(await transport.requests { lovedLastFMMethod($0) == "track.love" }.count == 1)
        let readsAfterLove = await lovedWaitForRequests(transport) { requests in
            requests.filter { lovedLastFMMethod($0) == "user.getlovedtracks" }.count == 2
        }
        #expect(readsAfterLove.filter { lovedLastFMMethod($0) == "user.getlovedtracks" }.count == 2)
        #expect(await lovedWaitUntil { runtime.state.lovedState.rows.count == 1 })
        #expect(runtime.state.feedbackByTrack[identity]?.score == .loved)
    }

    // MARK: - Authentication and readiness

    @Test func needsSignInSendsNoReadAndOffersNoUnlove() async throws {
        let database = try TemporaryDatabase()
        let transport = LovedTransport { _ in
            HTTPResponse(statusCode: 200, body: Data("{}".utf8))
        }
        let (runtime, store) = try makeLovedRuntime(
            database: database,
            clock: FakeClock(base),
            transport: transport,
        )
        await runtime.start()
        let connection = try await runtime.linkVerified(
            kind: .lastFM,
            credential: "session-key",
            identity: ServiceIdentity(name: "listener"),
        )
        var updated = connection
        updated.authState = .needsSignIn
        _ = try await store.save(updated)
        await runtime.reloadConnections()

        await runtime.loved?.show()
        #expect(await transport.requestCount() == 0)
        #expect(runtime.state.lovedState.phase == .failed(.needsSignIn(.signedOut)))
        #expect(runtime.state.lovedState.canUnlove == false)
        #expect(runtime.state.lovedState.rows.isEmpty)
    }

    @Test func aPausedConnectionStillReadsButOffersNoUnlove() async throws {
        let database = try TemporaryDatabase()
        let transport = LovedTransport { request in
            if lovedLastFMMethod(request) == "user.getlovedtracks" {
                return lovedLastFMResponse([LovedLastFMRow("Example Track One")], page: 1, totalPages: 1)
            }
            return HTTPResponse(statusCode: 404, body: Data())
        }
        let (runtime, _) = try makeLovedRuntime(
            database: database,
            clock: FakeClock(base),
            transport: transport,
        )
        await runtime.start()
        let connection = try await runtime.linkVerified(
            kind: .lastFM,
            credential: "session-key",
            identity: ServiceIdentity(name: "listener"),
        )
        try await runtime.setConnectionEnabled(id: #require(connection.id), enabled: false)

        await runtime.loved?.show()
        #expect(await transport.requestCount() == 1)
        #expect(runtime.state.lovedState.rows.count == 1)
        #expect(runtime.state.lovedState.canUnlove == false)
        #expect(runtime.state.lovedState.unloveUnavailableReason?.contains("paused") == true)
    }

    @Test func missingCredentialSendsNoRead() async throws {
        let database = try TemporaryDatabase()
        let credentials = MemoryCredentialStore()
        let transport = LovedTransport { _ in
            HTTPResponse(statusCode: 200, body: Data("{}".utf8))
        }
        let (runtime, _) = try makeLovedRuntime(
            database: database,
            clock: FakeClock(base),
            transport: transport,
            credentials: credentials,
        )
        await runtime.start()
        let connection = try await runtime.linkVerified(
            kind: .listenBrainz,
            credential: "demo-token",
            identity: ServiceIdentity(name: "listener"),
        )
        try await credentials.deleteCredential(forConnection: #require(connection.id))

        await runtime.loved?.show()
        #expect(await transport.requestCount() == 0)
        #expect(runtime.state.lovedState.phase == .failed(.needsSignIn(.credentialMissing)))
        #expect(runtime.state.lovedState.canUnlove == false)
    }

    @Test func anUnreadableCredentialSendsNoRead() async throws {
        let database = try TemporaryDatabase()
        let credentials = UnreadableCredentialStore()
        let transport = LovedTransport { _ in
            HTTPResponse(statusCode: 200, body: Data("{}".utf8))
        }
        let (runtime, _) = try makeLovedRuntime(
            database: database,
            clock: FakeClock(base),
            transport: transport,
            credentials: credentials,
        )
        await runtime.start()
        _ = try await runtime.linkVerified(
            kind: .listenBrainz,
            credential: "demo-token",
            identity: ServiceIdentity(name: "listener"),
        )

        await runtime.loved?.show()
        #expect(await transport.requestCount() == 0)
        #expect(runtime.state.lovedState.phase == .failed(.needsSignIn(.credentialUnavailable)))
        #expect(runtime.state.lovedState.canUnlove == false)
    }

    @Test func aRejectedRefreshKeepsRowsAndLeavesTheConnectionSignedIn() async throws {
        let database = try TemporaryDatabase()
        let mode = LovedReadMode()
        let transport = LovedTransport { request in
            if await mode.current() == .unauthorized {
                return HTTPResponse(statusCode: 401, body: Data())
            }
            if lovedFeedbackQuery(request) != nil {
                return lovedListenBrainzResponse(
                    [LovedListenBrainzItem(title: "Example Track One", mbid: "mbid-a")],
                    totalCount: 1,
                )
            }
            return HTTPResponse(statusCode: 404, body: Data())
        }
        let (runtime, _) = try makeLovedRuntime(
            database: database,
            clock: FakeClock(base),
            transport: transport,
        )
        await runtime.start()
        _ = try await runtime.linkVerified(
            kind: .listenBrainz,
            credential: "demo-token",
            identity: ServiceIdentity(name: "listener"),
        )
        await runtime.loved?.show()
        #expect(runtime.state.lovedState.rows.count == 1)

        await mode.set(.unauthorized)
        await runtime.loved?.refresh()
        #expect(runtime.state.lovedState.rows.count == 1)
        #expect(
            runtime.state.lovedState.refreshFailure
                == LovedFailure.needsSignIn(.rejected),
        )
        #expect(
            runtime.state.lovedState.refreshFailure.map {
                LovedCopy.failureMessage($0, service: "ListenBrainz", retryAt: nil)
            } == "ListenBrainz rejected the saved credential. Sign in on Services.",
        )
        #expect(runtime.state.currentConnection?.authState == ConnectionAuthState.signedIn)
        #expect(runtime.state.lovedState.canUnlove == false)
    }

    // MARK: - Failure and rate limit

    @Test func aFailedFirstReadIsRecoveredByTryAgain() async throws {
        let database = try TemporaryDatabase()
        let mode = LovedReadMode()
        let transport = LovedTransport { request in
            if await mode.current() == .serverError {
                return HTTPResponse(statusCode: 500, body: Data())
            }
            if lovedLastFMMethod(request) == "user.getlovedtracks" {
                return lovedLastFMResponse([LovedLastFMRow("Example Track One")], page: 1, totalPages: 1)
            }
            return HTTPResponse(statusCode: 404, body: Data())
        }
        let (runtime, _) = try makeLovedRuntime(
            database: database,
            clock: FakeClock(base),
            transport: transport,
        )
        await runtime.start()
        _ = try await runtime.linkVerified(
            kind: .lastFM,
            credential: "session-key",
            identity: ServiceIdentity(name: "listener"),
        )
        await mode.set(.serverError)
        await runtime.loved?.show()
        #expect(runtime.state.lovedState.phase == .failed(.offline))
        #expect(runtime.state.lovedState.rows.isEmpty)

        await mode.set(.success)
        await runtime.loved?.refresh()
        #expect(runtime.state.lovedState.phase == .ready)
        #expect(runtime.state.lovedState.rows.count == 1)
        #expect(runtime.state.lovedState.refreshFailure == nil)
    }

    @Test func aRateLimitSuppressesImmediateRetryUntilTheHint() async throws {
        let database = try TemporaryDatabase()
        let clock = FakeClock(base)
        let mode = LovedReadMode()
        let transport = LovedTransport { request in
            switch await mode.current() {
            case let .rateLimited(seconds):
                return HTTPResponse(
                    statusCode: 429,
                    headers: ["Retry-After": String(seconds)],
                    body: Data(),
                )
            case .serverError:
                return HTTPResponse(statusCode: 500, body: Data())
            case .unauthorized:
                return HTTPResponse(statusCode: 401, body: Data())
            case .success:
                if lovedLastFMMethod(request) == "user.getlovedtracks" {
                    return lovedLastFMResponse(
                        [LovedLastFMRow("Example Track One")],
                        page: 1,
                        totalPages: 1,
                    )
                }
                return HTTPResponse(statusCode: 404, body: Data())
            }
        }
        let (runtime, _) = try makeLovedRuntime(
            database: database,
            clock: clock,
            transport: transport,
        )
        await runtime.start()
        _ = try await runtime.linkVerified(
            kind: .lastFM,
            credential: "session-key",
            identity: ServiceIdentity(name: "listener"),
        )
        await runtime.loved?.show()
        #expect(runtime.state.lovedState.rows.count == 1)

        await mode.set(.rateLimited(seconds: 30))
        await runtime.loved?.refresh()
        #expect(runtime.state.lovedState.rows.count == 1)
        #expect(runtime.state.lovedState.refreshFailure == .rateLimited(retryAfter: 30))
        #expect(runtime.state.lovedState.retryNotBefore == base.addingTimeInterval(30))
        let countAfterLimit = await transport.requestCount()

        await mode.set(.success)
        await runtime.loved?.refresh()
        #expect(await transport.requestCount() == countAfterLimit)

        clock.advance(to: base.addingTimeInterval(31))
        await runtime.loved?.refresh()
        #expect(await transport.requestCount() == countAfterLimit + 1)
        #expect(runtime.state.lovedState.rows.count == 1)
        #expect(runtime.state.lovedState.refreshFailure == nil)
    }

    @Test func allOmittedRowsDoNotClaimAnEmptyAccount() async throws {
        let database = try TemporaryDatabase()
        let transport = LovedTransport { request in
            guard lovedFeedbackQuery(request) != nil else {
                return HTTPResponse(statusCode: 404, body: Data())
            }
            return lovedListenBrainzResponse(
                [
                    LovedListenBrainzItem(title: nil, artist: nil, album: nil, mbid: "mbid-one"),
                    LovedListenBrainzItem(title: nil, artist: nil, album: nil, mbid: "mbid-two"),
                ],
                totalCount: 2,
            )
        }
        let (runtime, _) = try makeLovedRuntime(
            database: database,
            clock: FakeClock(base),
            transport: transport,
        )
        await runtime.start()
        _ = try await runtime.linkVerified(
            kind: .listenBrainz,
            credential: "demo-token",
            identity: ServiceIdentity(name: "listener"),
        )
        await runtime.loved?.show()

        #expect(runtime.state.lovedState.phase == .metadataUnavailable)
        #expect(runtime.state.lovedState.omitted == 2)
        #expect(runtime.state.lovedState.rows.isEmpty)
    }

    @Test func anEmptyFeedbackPageStopsPagingEvenWithAStaleTotal() async throws {
        let database = try TemporaryDatabase()
        let transport = LovedTransport { request in
            guard lovedFeedbackQuery(request) != nil else {
                return HTTPResponse(statusCode: 404, body: Data())
            }
            // A stale or filtered total must not make an empty page repeat.
            return lovedListenBrainzResponse([], totalCount: 5)
        }
        let (runtime, _) = try makeLovedRuntime(
            database: database,
            clock: FakeClock(base),
            transport: transport,
        )
        await runtime.start()
        _ = try await runtime.linkVerified(
            kind: .listenBrainz,
            credential: "demo-token",
            identity: ServiceIdentity(name: "listener"),
        )
        await runtime.loved?.show()

        #expect(runtime.state.lovedState.rows.isEmpty)
        #expect(runtime.state.lovedState.hasMore == false)
        #expect(runtime.state.lovedState.phase == .empty)
        #expect(await transport.requests { lovedFeedbackQuery($0) != nil }.count == 1)
    }

    @Test func anEmptySuccessIsNotAnError() async throws {
        let database = try TemporaryDatabase()
        let transport = LovedTransport { request in
            if lovedLastFMMethod(request) == "user.getlovedtracks" {
                return lovedLastFMResponse([], page: 1, totalPages: 0)
            }
            return HTTPResponse(statusCode: 404, body: Data())
        }
        let (runtime, _) = try makeLovedRuntime(
            database: database,
            clock: FakeClock(base),
            transport: transport,
        )
        await runtime.start()
        _ = try await runtime.linkVerified(
            kind: .lastFM,
            credential: "session-key",
            identity: ServiceIdentity(name: "listener"),
        )
        await runtime.loved?.show()
        #expect(runtime.state.lovedState.phase == .empty)
        #expect(runtime.state.lovedState.rows.isEmpty)
        #expect(runtime.state.lovedState.refreshFailure == nil)
    }

    @Test func anUnsupportedCustomRootShowsAnUnavailableState() async throws {
        let database = try TemporaryDatabase()
        let root = try #require(ServiceEndpoint(normalizing: "https://compat.example"))
        let transport = LovedTransport { _ in
            HTTPResponse(statusCode: 404, body: Data())
        }
        let (runtime, _) = try makeLovedRuntime(
            database: database,
            clock: FakeClock(base),
            transport: transport,
        )
        await runtime.start()
        _ = try await runtime.linkVerified(
            kind: .listenBrainz,
            credential: "demo-token",
            identity: ServiceIdentity(name: "listener"),
            endpoint: root,
        )
        await runtime.loved?.show()

        #expect(
            runtime.state.lovedState.phase
                == .unavailable("This ListenBrainz-compatible server does not provide loved tracks."),
        )
        #expect(runtime.state.lovedState.rows.isEmpty)
        #expect(runtime.state.lovedState.canUnlove == false)
    }

    // MARK: - Account isolation

    @Test func switchingConnectionDropsRowsAndIgnoresTheLateReply() async throws {
        let database = try TemporaryDatabase()
        let transport = LovedTransport(
            hold: { request in
                lovedLastFMMethod(request) == "user.getlovedtracks"
                    && lovedLastFMUser(request) == "listener-one"
            },
            handler: { request in
                if lovedLastFMMethod(request) == "user.getlovedtracks" {
                    return lovedLastFMResponse(
                        [LovedLastFMRow("Old Account Row")],
                        page: 1,
                        totalPages: 1,
                    )
                }
                if lovedFeedbackQuery(request) != nil {
                    return lovedListenBrainzResponse(
                        [LovedListenBrainzItem(title: "New Account Row", mbid: "new-mbid")],
                        totalCount: 1,
                    )
                }
                return HTTPResponse(statusCode: 404, body: Data())
            },
        )
        let (runtime, _) = try makeLovedRuntime(
            database: database,
            clock: FakeClock(base),
            transport: transport,
        )
        await runtime.start()
        _ = try await runtime.linkVerified(
            kind: .lastFM,
            credential: "session-key",
            identity: ServiceIdentity(name: "listener-one"),
        )

        let show = Task { await runtime.loved?.show() }
        #expect(await transport.waitUntilEntered())

        _ = try await runtime.linkVerified(
            kind: .listenBrainz,
            credential: "demo-token",
            identity: ServiceIdentity(name: "listener-two"),
        )
        #expect(await lovedWaitUntil { runtime.state.lovedState.rows.first?.title == "New Account Row" })
        #expect(runtime.state.lovedState.sourceLabel == "ListenBrainz · listener-two")

        await transport.release()
        let shown = await lovedAwait(show)
        #expect(shown != nil, "the show completes")
        guard shown != nil else { return }
        await turnMainActor()
        #expect(runtime.state.lovedState.rows.map(\.title) == ["New Account Row"])
        #expect(runtime.state.lovedState.sourceLabel == "ListenBrainz · listener-two")
    }

    // MARK: - Identity reconciliation

    @Test func aHistoryUnloveClearsEveryLocalFeedbackIdentityForTheSameTrack() async throws {
        let database = try TemporaryDatabase()
        let transport = LovedTransport { request in
            if lovedLastFMMethod(request) == "user.getlovedtracks" {
                return lovedLastFMResponse(
                    [LovedLastFMRow("Example Track One")],
                    page: 1,
                    totalPages: 1,
                )
            }
            if lovedLastFMMethod(request) == "track.love"
                || lovedLastFMMethod(request) == "track.unlove" {
                return lastFMEmptyResponse()
            }
            return HTTPResponse(statusCode: 404, body: Data())
        }
        let (runtime, store) = try makeLovedRuntime(
            database: database,
            clock: FakeClock(base),
            transport: transport,
        )
        await runtime.start()
        _ = try await runtime.linkVerified(
            kind: .lastFM,
            credential: "session-key",
            identity: ServiceIdentity(name: "listener"),
        )
        await runtime.loved?.show()
        #expect(runtime.state.lovedState.rows.count == 1)

        let track = Track(
            title: "Example Track One",
            artist: "Example Artist",
            album: "Example Album",
            albumArtist: "Example Album Artist",
        )
        let identity = ListenMetadata(track).identity
        try await store.setFeedback(.loved, for: identity, at: base)
        let listen = try #require(
            try await store.insert(
                Listen(
                    raw: ListenMetadata(track),
                    processed: ListenMetadata(track),
                    bundleID: "com.apple.Music",
                    duration: 200,
                    playedDuration: 200,
                    startedAt: base,
                    capturedAt: base,
                ),
                targets: [],
            ),
        )

        await runtime.toggleLove(for: listen)
        #expect(runtime.state.lovedState.rows.isEmpty)
        #expect(runtime.state.feedbackByTrack[identity] == nil)
        #expect(try await store.feedback(for: [identity]).isEmpty)
        #expect(await transport.requests { lovedLastFMMethod($0) == "track.unlove" }.count == 1)

        await runtime.toggleLove(for: listen)
        #expect(await transport.requests { lovedLastFMMethod($0) == "track.love" }.count == 1)
        #expect(runtime.state.feedbackByTrack[identity]?.score == .loved)
    }

    @Test func unlovingASecondRowWithTheSameMetadataPostsAndRemovesThatRow() async throws {
        let database = try TemporaryDatabase()
        let transport = LovedTransport { request in
            if lovedFeedbackQuery(request) != nil {
                return lovedListenBrainzResponse(
                    [
                        LovedListenBrainzItem(
                            title: "Example Track One",
                            mbid: "mbid-one",
                        ),
                        LovedListenBrainzItem(
                            title: "Example Track One",
                            mbid: "mbid-two",
                        ),
                    ],
                    totalCount: 2,
                )
            }
            if lovedIsFeedbackPost(request) {
                return jsonResponse(["status": "ok"])
            }
            return HTTPResponse(statusCode: 404, body: Data())
        }
        let (runtime, _) = try makeLovedRuntime(
            database: database,
            clock: FakeClock(base),
            transport: transport,
        )
        await runtime.start()
        _ = try await runtime.linkVerified(
            kind: .listenBrainz,
            credential: "demo-token",
            identity: ServiceIdentity(name: "listener"),
        )
        await runtime.loved?.show()
        #expect(runtime.state.lovedState.rows.count == 2)
        let second = try #require(runtime.state.lovedState.rows.last)
        #expect(second.reference == .mbid("mbid-two"))

        let confirmed = await runtime.unloveLovedRow(second)
        #expect(confirmed)
        #expect(runtime.state.lovedState.rows.map(\.id) == ["listenbrainz:mbid:mbid-one"])
        let posts = await transport.requests { lovedIsFeedbackPost($0) }
        #expect(posts.count == 1)
        #expect(try lovedFeedbackReference(#require(posts.first)) == "mbid-two")
    }

    @Test func unlovingThroughTheStripRereadsWhenTwoRowsShareTitleAndArtist() async throws {
        let database = try TemporaryDatabase()
        let transport = LovedTransport { request in
            if lovedLastFMMethod(request) == "user.getlovedtracks" {
                return lovedLastFMResponse(
                    [
                        LovedLastFMRow("Example Track One", mbid: "mbid-one"),
                        LovedLastFMRow("Example Track One", mbid: "mbid-two"),
                    ],
                    page: 1,
                    totalPages: 1,
                )
            }
            if lovedLastFMMethod(request) == "track.love"
                || lovedLastFMMethod(request) == "track.unlove" {
                return lastFMEmptyResponse()
            }
            return HTTPResponse(statusCode: 404, body: Data())
        }
        let (runtime, store) = try makeLovedRuntime(
            database: database,
            clock: FakeClock(base),
            transport: transport,
        )
        await runtime.start()
        _ = try await runtime.linkVerified(
            kind: .lastFM,
            credential: "session-key",
            identity: ServiceIdentity(name: "listener"),
        )
        await runtime.loved?.show()
        let track = Track(
            title: "Example Track One",
            artist: "Example Artist",
            album: "Example Album",
            albumArtist: "Example Album Artist",
        )
        let identity = ListenMetadata(track).identity
        try await store.setFeedback(.loved, for: identity, at: base)
        runtime.state.nowPlaying = MediaSample(
            track: track,
            elapsed: 10,
            playbackRate: 1,
            isPlaying: true,
        )

        await runtime.toggleLoveForCurrentTrack()
        let requests = await lovedWaitForRequests(transport) { all in
            all.filter { lovedLastFMMethod($0) == "user.getlovedtracks" }.count == 2
        }
        #expect(requests.filter { lovedLastFMMethod($0) == "user.getlovedtracks" }.count == 2)
        // No row was removed by guess: the first page was read again.
        #expect(runtime.state.lovedState.rows.count == 2)
    }

    // MARK: - In-flight reads

    @Test func aHeldLoadMoreAfterUnloveIsDiscardedAndKeepsTheSteppedOffset() async throws {
        let database = try TemporaryDatabase()
        let counter = LovedCounter()
        let firstPage = LovedPageCounter()
        let transport = LovedTransport(
            hold: { request in
                guard lovedFeedbackQuery(request) != nil else { return false }
                return counter.next() == 2
            },
            handler: { request in
                guard let query = lovedFeedbackQuery(request) else {
                    return HTTPResponse(statusCode: 404, body: Data())
                }
                if query.offset == 0 {
                    let read = await firstPage.next(0)
                    let rows = read == 1
                        ? [LovedListenBrainzItem(title: "Example Track One", mbid: "mbid-a")]
                        : [
                            LovedListenBrainzItem(title: "Example Track Two", mbid: "mbid-b"),
                            LovedListenBrainzItem(title: "Example Track Three", mbid: "mbid-c"),
                        ]
                    return lovedListenBrainzResponse(rows, totalCount: 4)
                }
                return lovedListenBrainzResponse(
                    [
                        LovedListenBrainzItem(title: "Example Track Two", mbid: "mbid-b"),
                        LovedListenBrainzItem(title: "Example Track Three", mbid: "mbid-c"),
                    ],
                    totalCount: 4,
                )
            },
        )
        let (runtime, _) = try makeLovedRuntime(
            database: database,
            clock: FakeClock(base),
            transport: transport,
        )
        await runtime.start()
        let connection = try await runtime.linkVerified(
            kind: .listenBrainz,
            credential: "demo-token",
            identity: ServiceIdentity(name: "listener"),
        )
        await runtime.loved?.show()
        let row = try #require(runtime.state.lovedState.rows.first)

        let load = Task { await runtime.loved?.loadMore() }
        #expect(await transport.waitUntilEntered())
        runtime.loved?.feedbackSucceeded(.unlove, track: row.track, connections: [connection])
        #expect(runtime.state.lovedState.rows.isEmpty)
        await transport.release()
        let loaded = await lovedAwait(load)
        #expect(loaded != nil, "the load-more completes")
        guard loaded != nil else { return }
        #expect(runtime.state.lovedState.rows.isEmpty)
        #expect(runtime.state.lovedState.isLoadingMore == false)

        await runtime.loved?.loadMore()
        let later = await transport.requests { lovedFeedbackQuery($0) != nil }
        #expect(try lovedFeedbackQuery(#require(later.last))?.offset == 0)
        #expect(runtime.state.lovedState.rows.map(\.title) == ["Example Track Two", "Example Track Three"])
    }

    @Test func aHeldPageLoadMoreAfterUnloveKeepsTheLastPageCursor() async throws {
        let database = try TemporaryDatabase()
        let counter = LovedCounter()
        let transport = LovedTransport(
            hold: { request in
                guard lovedLastFMMethod(request) == "user.getlovedtracks" else { return false }
                return counter.next() == 3
            },
            handler: { request in
                guard let page = formParameters(request)["page"] else {
                    return HTTPResponse(statusCode: 404, body: Data())
                }
                switch page {
                case "1":
                    return lovedLastFMResponse(
                        [LovedLastFMRow("Example Track One"), LovedLastFMRow("Example Track Two")],
                        page: 1,
                        totalPages: 3,
                    )
                case "2":
                    return lovedLastFMResponse(
                        [LovedLastFMRow("Example Track Three"), LovedLastFMRow("Example Track Four")],
                        page: 2,
                        totalPages: 3,
                    )
                default:
                    return lovedLastFMResponse(
                        [LovedLastFMRow("Example Track Five")],
                        page: 3,
                        totalPages: 3,
                    )
                }
            },
        )
        let (runtime, _) = try makeLovedRuntime(
            database: database,
            clock: FakeClock(base),
            transport: transport,
        )
        await runtime.start()
        let connection = try await runtime.linkVerified(
            kind: .lastFM,
            credential: "session-key",
            identity: ServiceIdentity(name: "listener"),
        )
        await runtime.loved?.show()
        await runtime.loved?.loadMore()
        #expect(runtime.state.lovedState.rows.count == 4)

        let load = Task { await runtime.loved?.loadMore() }
        #expect(await transport.waitUntilEntered())
        let first = try #require(runtime.state.lovedState.rows.first)
        runtime.loved?.feedbackSucceeded(.unlove, track: first.track, connections: [connection])
        #expect(runtime.state.lovedState.rows.count == 3)
        await transport.release()
        let loaded = await lovedAwait(load)
        #expect(loaded != nil, "the load-more completes")
        guard loaded != nil else { return }
        #expect(runtime.state.lovedState.rows.count == 3)
        #expect(runtime.state.lovedState.isLoadingMore == false)

        await runtime.loved?.loadMore()
        let reads = await transport.requests { lovedLastFMMethod($0) == "user.getlovedtracks" }
        #expect(reads.compactMap { formParameters($0)["page"] }.last == "2")
        #expect(Set(runtime.state.lovedState.rows.map(\.id)).count == runtime.state.lovedState.rows.count)
    }

    @Test func aHeldRefreshAfterUnloveDoesNotRestoreTheRow() async throws {
        let database = try TemporaryDatabase()
        let counter = LovedCounter()
        let transport = LovedTransport(
            hold: { request in
                guard lovedLastFMMethod(request) == "user.getlovedtracks" else { return false }
                return counter.next() == 2
            },
            handler: { request in
                if lovedLastFMMethod(request) == "user.getlovedtracks" {
                    return lovedLastFMResponse(
                        [LovedLastFMRow("Example Track One"), LovedLastFMRow("Example Track Two")],
                        page: 1,
                        totalPages: 1,
                    )
                }
                return HTTPResponse(statusCode: 404, body: Data())
            },
        )
        let (runtime, _) = try makeLovedRuntime(
            database: database,
            clock: FakeClock(base),
            transport: transport,
        )
        await runtime.start()
        let connection = try await runtime.linkVerified(
            kind: .lastFM,
            credential: "session-key",
            identity: ServiceIdentity(name: "listener"),
        )
        await runtime.loved?.show()

        let refresh = Task { await runtime.loved?.refresh() }
        #expect(await transport.waitUntilEntered())
        let first = try #require(runtime.state.lovedState.rows.first)
        runtime.loved?.feedbackSucceeded(.unlove, track: first.track, connections: [connection])
        await transport.release()
        let refreshed = await lovedAwait(refresh)
        #expect(refreshed != nil, "the refresh completes")
        guard refreshed != nil else { return }
        await turnMainActor()
        #expect(runtime.state.lovedState.rows.map(\.title) == ["Example Track Two"])
    }

    @Test func loadMoreDuringARefreshSendsNoRequest() async throws {
        let database = try TemporaryDatabase()
        let counter = LovedCounter()
        let transport = LovedTransport(
            hold: { request in
                guard lovedLastFMMethod(request) == "user.getlovedtracks" else { return false }
                return counter.next() == 2
            },
            handler: { request in
                if lovedLastFMMethod(request) == "user.getlovedtracks" {
                    return lovedLastFMResponse([LovedLastFMRow("Example Track One")], page: 1, totalPages: 2)
                }
                return HTTPResponse(statusCode: 404, body: Data())
            },
        )
        let (runtime, _) = try makeLovedRuntime(
            database: database,
            clock: FakeClock(base),
            transport: transport,
        )
        await runtime.start()
        _ = try await runtime.linkVerified(
            kind: .lastFM,
            credential: "session-key",
            identity: ServiceIdentity(name: "listener"),
        )
        await runtime.loved?.show()

        let refresh = Task { await runtime.loved?.refresh() }
        #expect(await transport.waitUntilEntered())
        let before = await transport.requestCount()
        await runtime.loved?.loadMore()
        #expect(await transport.requestCount() == before)
        #expect(runtime.state.lovedState.isLoadingMore == false)
        await transport.release()
        let refreshed = await lovedAwait(refresh)
        #expect(refreshed != nil, "the refresh completes")
        guard refreshed != nil else { return }
    }

    // MARK: - Final page and omissions

    @Test func unlovingTheOnlyRowOnTheFinalPageDoesNotInventAnotherPage() async throws {
        let database = try TemporaryDatabase()
        let transport = LovedTransport { request in
            if lovedLastFMMethod(request) == "user.getlovedtracks" {
                return lovedLastFMResponse([LovedLastFMRow("Example Track One")], page: 1, totalPages: 1)
            }
            return HTTPResponse(statusCode: 404, body: Data())
        }
        let (runtime, _) = try makeLovedRuntime(
            database: database,
            clock: FakeClock(base),
            transport: transport,
        )
        await runtime.start()
        let connection = try await runtime.linkVerified(
            kind: .lastFM,
            credential: "session-key",
            identity: ServiceIdentity(name: "listener"),
        )
        await runtime.loved?.show()
        let row = try #require(runtime.state.lovedState.rows.first)
        runtime.loved?.feedbackSucceeded(.unlove, track: row.track, connections: [connection])

        #expect(runtime.state.lovedState.phase == .empty)
        #expect(runtime.state.lovedState.hasMore == false)
        #expect(await transport.requests { lovedLastFMMethod($0) == "user.getlovedtracks" }.count == 1)
    }

    @Test func unlovingTheLastLoadedRowWithMorePagesNeverPublishesEmpty() async throws {
        let database = try TemporaryDatabase()
        let counter = LovedPageCounter()
        let transport = LovedTransport { request in
            guard let page = formParameters(request)["page"] else {
                return HTTPResponse(statusCode: 404, body: Data())
            }
            switch page {
            case "1":
                let read = await counter.next(1)
                return lovedLastFMResponse(
                    [LovedLastFMRow(read == 1 ? "Example Track One" : "Example Track Two")],
                    page: 1,
                    totalPages: 2,
                )
            default:
                return lovedLastFMResponse([LovedLastFMRow("Example Track Three")], page: 2, totalPages: 2)
            }
        }
        let (runtime, _) = try makeLovedRuntime(
            database: database,
            clock: FakeClock(base),
            transport: transport,
        )
        await runtime.start()
        let connection = try await runtime.linkVerified(
            kind: .lastFM,
            credential: "session-key",
            identity: ServiceIdentity(name: "listener"),
        )
        await runtime.loved?.show()
        let row = try #require(runtime.state.lovedState.rows.first)
        runtime.loved?.feedbackSucceeded(.unlove, track: row.track, connections: [connection])

        #expect(runtime.state.lovedState.phase != .empty)
        #expect(runtime.state.lovedState.hasMore)
        await runtime.loved?.loadMore()
        #expect(runtime.state.lovedState.rows.contains { $0.title == "Example Track Two" })
        await runtime.loved?.loadMore()
        let reads = await transport.requests { lovedLastFMMethod($0) == "user.getlovedtracks" }
        #expect(reads.compactMap { formParameters($0)["page"] }.last == "2")
    }

    @Test func aRefreshReplacesTheCountedOmittedPages() async throws {
        let database = try TemporaryDatabase()
        let transport = LovedTransport { request in
            guard let page = formParameters(request)["page"] else {
                return HTTPResponse(statusCode: 404, body: Data())
            }
            switch page {
            case "1":
                return lovedLastFMResponse(
                    [LovedLastFMRow("Example Track One")],
                    page: 1,
                    totalPages: 3,
                    omitted: 1,
                )
            default:
                return lovedLastFMResponse(
                    [LovedLastFMRow("Example Track Two")],
                    page: 2,
                    totalPages: 3,
                    omitted: 1,
                )
            }
        }
        let (runtime, _) = try makeLovedRuntime(
            database: database,
            clock: FakeClock(base),
            transport: transport,
        )
        await runtime.start()
        _ = try await runtime.linkVerified(
            kind: .lastFM,
            credential: "session-key",
            identity: ServiceIdentity(name: "listener"),
        )
        await runtime.loved?.show()
        await runtime.loved?.loadMore()
        #expect(runtime.state.lovedState.omitted == 2)
        #expect(runtime.state.lovedState.rows.count == 2)

        await runtime.loved?.refresh()
        #expect(runtime.state.lovedState.omitted == 1)
        #expect(runtime.state.lovedState.rows.count == 1)

        await runtime.loved?.loadMore()
        #expect(runtime.state.lovedState.omitted == 2)
        #expect(runtime.state.lovedState.rows.count == 2)
    }

    @Test func aDiscardedRefreshKeepsTheCountedOmittedPages() async throws {
        let database = try TemporaryDatabase()
        let counter = LovedCounter()
        let transport = LovedTransport(
            hold: { request in
                guard lovedLastFMMethod(request) == "user.getlovedtracks" else { return false }
                return counter.next() == 3
            },
            handler: { request in
                guard let page = formParameters(request)["page"] else {
                    return HTTPResponse(statusCode: 404, body: Data())
                }
                switch page {
                case "1":
                    return lovedLastFMResponse(
                        [LovedLastFMRow("Example Track One")],
                        page: 1,
                        totalPages: 3,
                        omitted: 1,
                    )
                default:
                    return lovedLastFMResponse(
                        [LovedLastFMRow("Example Track Two")],
                        page: 2,
                        totalPages: 3,
                        omitted: 1,
                    )
                }
            },
        )
        let (runtime, _) = try makeLovedRuntime(
            database: database,
            clock: FakeClock(base),
            transport: transport,
        )
        await runtime.start()
        let connection = try await runtime.linkVerified(
            kind: .lastFM,
            credential: "session-key",
            identity: ServiceIdentity(name: "listener"),
        )
        await runtime.loved?.show()
        await runtime.loved?.loadMore()
        #expect(runtime.state.lovedState.omitted == 2)

        let refresh = Task { await runtime.loved?.refresh() }
        #expect(await transport.waitUntilEntered())
        let first = try #require(runtime.state.lovedState.rows.first)
        runtime.loved?.feedbackSucceeded(.unlove, track: first.track, connections: [connection])
        #expect(runtime.state.lovedState.omitted == 2)
        await transport.release()
        let refreshed = await lovedAwait(refresh)
        #expect(refreshed != nil, "the refresh completes")
        guard refreshed != nil else { return }
        await turnMainActor()
        #expect(runtime.state.lovedState.omitted == 2)

        await runtime.loved?.loadMore()
        #expect(runtime.state.lovedState.omitted == 2)
    }

    @Test func reReadingAPageLeavesOmittedUnchanged() async throws {
        let database = try TemporaryDatabase()
        let pageTwo = LovedPageCounter()
        let transport = LovedTransport { request in
            guard let page = formParameters(request)["page"] else {
                return HTTPResponse(statusCode: 404, body: Data())
            }
            switch page {
            case "1":
                return lovedLastFMResponse(
                    [LovedLastFMRow("Example Track One")],
                    page: 1,
                    totalPages: 3,
                    omitted: 1,
                )
            default:
                let read = await pageTwo.next(2)
                return lovedLastFMResponse(
                    [LovedLastFMRow(read == 1 ? "Example Track Two" : "Example Track Three")],
                    page: 2,
                    totalPages: 3,
                    omitted: 1,
                )
            }
        }
        let (runtime, _) = try makeLovedRuntime(
            database: database,
            clock: FakeClock(base),
            transport: transport,
        )
        await runtime.start()
        let connection = try await runtime.linkVerified(
            kind: .lastFM,
            credential: "session-key",
            identity: ServiceIdentity(name: "listener"),
        )
        await runtime.loved?.show()
        await runtime.loved?.loadMore()
        #expect(runtime.state.lovedState.omitted == 2)
        let last = try #require(runtime.state.lovedState.rows.last)
        runtime.loved?.feedbackSucceeded(.unlove, track: last.track, connections: [connection])
        #expect(runtime.state.lovedState.omitted == 2)

        await runtime.loved?.loadMore()
        #expect(runtime.state.lovedState.omitted == 2)
        #expect(runtime.state.lovedState.rows.map(\.title) == ["Example Track One", "Example Track Three"])
    }

    @Test func rowsRunningOutWithOmissionsIsMetadataUnavailable() async throws {
        let database = try TemporaryDatabase()
        let transport = LovedTransport { request in
            guard let page = formParameters(request)["page"] else {
                return HTTPResponse(statusCode: 404, body: Data())
            }
            _ = page
            return lovedLastFMResponse(
                [LovedLastFMRow("Example Track One")],
                page: 1,
                totalPages: 1,
                omitted: 1,
            )
        }
        let (runtime, _) = try makeLovedRuntime(
            database: database,
            clock: FakeClock(base),
            transport: transport,
        )
        await runtime.start()
        let connection = try await runtime.linkVerified(
            kind: .lastFM,
            credential: "session-key",
            identity: ServiceIdentity(name: "listener"),
        )
        await runtime.loved?.show()
        let row = try #require(runtime.state.lovedState.rows.first)
        runtime.loved?.feedbackSucceeded(.unlove, track: row.track, connections: [connection])

        #expect(runtime.state.lovedState.rows.isEmpty)
        #expect(runtime.state.lovedState.omitted == 1)
        #expect(runtime.state.lovedState.phase == .metadataUnavailable)
    }

    // MARK: - Rate-limit deadline

    @Test func aRateLimitEndsAtTheDeadlineAndRestoresRetryAndUnlove() async throws {
        let database = try TemporaryDatabase()
        let clock = FakeClock(base)
        let mode = LovedReadMode()
        let transport = LovedTransport { request in
            if await mode.current() == .rateLimited(seconds: 30) {
                return HTTPResponse(
                    statusCode: 429,
                    headers: ["Retry-After": "30"],
                    body: Data(),
                )
            }
            if lovedLastFMMethod(request) == "user.getlovedtracks" {
                return lovedLastFMResponse([LovedLastFMRow("Example Track One")], page: 1, totalPages: 1)
            }
            return HTTPResponse(statusCode: 404, body: Data())
        }
        let (runtime, _) = try makeLovedRuntime(
            database: database,
            clock: clock,
            transport: transport,
        )
        await runtime.start()
        _ = try await runtime.linkVerified(
            kind: .lastFM,
            credential: "session-key",
            identity: ServiceIdentity(name: "listener"),
        )
        await runtime.loved?.show()
        #expect(runtime.state.lovedState.canUnlove)

        await mode.set(.rateLimited(seconds: 30))
        await runtime.loved?.refresh()
        let deadline = try #require(runtime.state.lovedState.retryNotBefore)
        #expect(deadline == base.addingTimeInterval(30))
        #expect(runtime.state.lovedState.canUnlove == false)

        clock.advance(to: deadline)
        #expect(await lovedWaitUntil { runtime.state.lovedState.retryNotBefore == nil })
        #expect(runtime.state.lovedState.canUnlove)

        await mode.set(.success)
        let before = await transport.requestCount()
        await runtime.loved?.refresh()
        #expect(await transport.requestCount() == before + 1)
        #expect(runtime.state.lovedState.rows.count == 1)
    }

    @Test func aRateLimitedFirstReadOffersRetryAfterTheHint() async throws {
        let database = try TemporaryDatabase()
        let clock = FakeClock(base)
        let mode = LovedReadMode()
        let transport = LovedTransport { request in
            if await mode.current() == .rateLimited(seconds: 30) {
                return HTTPResponse(
                    statusCode: 429,
                    headers: ["Retry-After": "30"],
                    body: Data(),
                )
            }
            if lovedLastFMMethod(request) == "user.getlovedtracks" {
                return lovedLastFMResponse([LovedLastFMRow("Example Track One")], page: 1, totalPages: 1)
            }
            return HTTPResponse(statusCode: 404, body: Data())
        }
        let (runtime, _) = try makeLovedRuntime(
            database: database,
            clock: clock,
            transport: transport,
        )
        await runtime.start()
        _ = try await runtime.linkVerified(
            kind: .lastFM,
            credential: "session-key",
            identity: ServiceIdentity(name: "listener"),
        )
        await mode.set(.rateLimited(seconds: 30))
        await runtime.loved?.show()
        #expect(runtime.state.lovedState.phase == .failed(.rateLimited(retryAfter: 30)))
        let deadline = try #require(runtime.state.lovedState.retryNotBefore)

        clock.advance(to: deadline)
        #expect(await lovedWaitUntil { runtime.state.lovedState.retryNotBefore == nil })
        await mode.set(.success)
        let before = await transport.requestCount()
        await runtime.loved?.refresh()
        #expect(await transport.requestCount() == before + 1)
        #expect(runtime.state.lovedState.phase == .ready)
        #expect(runtime.state.lovedState.rows.count == 1)
    }

    @Test func hidingCancelsTheRateLimitWake() async throws {
        let database = try TemporaryDatabase()
        let clock = FakeClock(base)
        let transport = LovedTransport { _ in
            HTTPResponse(statusCode: 429, headers: ["Retry-After": "30"], body: Data())
        }
        let (runtime, _) = try makeLovedRuntime(
            database: database,
            clock: clock,
            transport: transport,
        )
        await runtime.start()
        _ = try await runtime.linkVerified(
            kind: .lastFM,
            credential: "session-key",
            identity: ServiceIdentity(name: "listener"),
        )
        await runtime.loved?.show()
        let deadline = try #require(runtime.state.lovedState.retryNotBefore)
        runtime.loved?.hide()
        clock.advance(to: deadline)
        await turnMainActor()
        #expect(runtime.state.lovedState.phase == .idle)
        #expect(runtime.state.lovedState.retryNotBefore == nil)
    }

    // MARK: - Rejected credential copy

    @Test func aRejectedFirstReadNamesTheCredential() async throws {
        let database = try TemporaryDatabase()
        let transport = LovedTransport { _ in
            HTTPResponse(statusCode: 401, body: Data())
        }
        let (runtime, _) = try makeLovedRuntime(
            database: database,
            clock: FakeClock(base),
            transport: transport,
        )
        await runtime.start()
        _ = try await runtime.linkVerified(
            kind: .listenBrainz,
            credential: "demo-token",
            identity: ServiceIdentity(name: "listener"),
        )
        await runtime.loved?.show()
        #expect(runtime.state.lovedState.phase == .failed(.needsSignIn(.rejected)))
        #expect(
            LovedCopy.failureMessage(.needsSignIn(.rejected), service: "ListenBrainz", retryAt: nil)
                == "ListenBrainz rejected the saved credential. Sign in on Services.",
        )
    }

    // MARK: - Feedback chain

    @Test func aLoveReReadDoesNotHoldTheFeedbackChain() async throws {
        let database = try TemporaryDatabase()
        let counter = LovedCounter()
        let transport = LovedTransport(
            hold: { request in
                guard lovedLastFMMethod(request) == "user.getlovedtracks" else { return false }
                return counter.next() == 2
            },
            handler: { request in
                if lovedLastFMMethod(request) == "user.getlovedtracks" {
                    return lovedLastFMResponse([LovedLastFMRow("Example Track One")], page: 1, totalPages: 1)
                }
                if lovedLastFMMethod(request) == "track.love"
                    || lovedLastFMMethod(request) == "track.unlove" {
                    return lastFMEmptyResponse()
                }
                return HTTPResponse(statusCode: 404, body: Data())
            },
        )
        let (runtime, _) = try makeLovedRuntime(
            database: database,
            clock: FakeClock(base),
            transport: transport,
        )
        await runtime.start()
        _ = try await runtime.linkVerified(
            kind: .lastFM,
            credential: "session-key",
            identity: ServiceIdentity(name: "listener"),
        )
        await runtime.loved?.show()
        let track = Track(
            title: "Example Track One",
            artist: "Example Artist",
            album: "Example Album",
            albumArtist: "Example Album Artist",
        )
        runtime.state.nowPlaying = MediaSample(
            track: track,
            elapsed: 10,
            playbackRate: 1,
            isPlaying: true,
        )

        await runtime.toggleLoveForCurrentTrack()
        #expect(await transport.waitUntilEntered())
        await runtime.toggleLoveForCurrentTrack()
        let requests = await lovedWaitForRequests(transport) { all in
            all.filter { lovedLastFMMethod($0) == "track.unlove" }.count == 1
        }
        #expect(requests.filter { lovedLastFMMethod($0) == "track.unlove" }.count == 1)
        #expect(runtime.state.lovedState.rows.isEmpty)

        await transport.release()
        await turnMainActor()
        #expect(runtime.state.lovedState.rows.isEmpty)
        #expect(runtime.state.feedbackByTrack[ListenMetadata(track).identity] == nil)
    }
}

// swiftlint:enable file_length type_body_length
