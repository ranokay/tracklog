import Foundation
import Testing
@testable import TracklogCore

@Suite("Last.fm errors")
@MainActor
struct LastFMErrorTests {
    private func adapter(_ responses: [HTTPResponse]) -> (LastFMAdapter, ScriptedTransport) {
        let transport = ScriptedTransport(responses)
        return (LastFMAdapter(transport: transport, appCredentials: lastFMTestCredentials), transport)
    }

    @Test func mapsEverySpecifiedServiceErrorCode() async throws {
        let cases: [(Int, ServiceFailure)] = [
            (4, .auth),
            (9, .auth),
            (14, .auth),
            (15, .auth),
            (10, .appCredentialAuth(.invalidKey)),
            (26, .appCredentialAuth(.suspendedKey)),
            (13, .appCredentialAuth(.invalidSignature)),
            (8, .retryable),
            (11, .retryable),
            (16, .retryable),
            (29, .rateLimited(retryAfter: nil)),
            (6, .rejected("The service rejected the request.")),
            (7, .rejected("The service rejected the request.")),
        ]

        for (code, expected) in cases {
            let (adapter, _) = adapter([lastFMErrorResponse(code: code)])
            await #expect(throws: expected) {
                _ = try await adapter.submit(
                    [lastFMTestListen()],
                    connection: lastFMTestConnection(),
                    credential: "session-key",
                )
            }
        }
    }

    @Test func mapsHTTPErrorsAndTimeouts() async throws {
        let rateLimited = adapter([
            HTTPResponse(statusCode: 429, headers: ["Retry-After": "17"], body: Data()),
        ])
        await #expect(throws: ServiceFailure.rateLimited(retryAfter: 17)) {
            _ = try await rateLimited.0.submit(
                [lastFMTestListen()],
                connection: lastFMTestConnection(),
                credential: "session-key",
            )
        }

        let serverError = adapter([HTTPResponse(statusCode: 503, body: Data())])
        await #expect(throws: ServiceFailure.retryable) {
            _ = try await serverError.0.submit(
                [lastFMTestListen()],
                connection: lastFMTestConnection(),
                credential: "session-key",
            )
        }

        let timeout = adapter([])
        let timedOut = LastFMAdapter(
            transport: ScriptedTransport(error: .timedOut),
            appCredentials: lastFMTestCredentials,
        )
        await #expect(throws: ServiceFailure.retryable) {
            _ = try await timedOut.submit(
                [lastFMTestListen()],
                connection: lastFMTestConnection(),
                credential: "session-key",
            )
        }
        #expect(await timeout.1.requests.isEmpty)
    }

    @Test func a5xxStaysRetryableEvenWithAnErrorBody() async throws {
        for (status, code) in [(503, 10), (500, 6), (502, 13)] {
            let (adapter, _) = adapter([
                lastFMErrorResponse(code: code, statusCode: status),
            ])
            await #expect(throws: ServiceFailure.retryable) {
                _ = try await adapter.submit(
                    [lastFMTestListen()],
                    connection: lastFMTestConnection(),
                    credential: "session-key",
                )
            }
        }
    }

    @Test func anHTTPRateLimitKeepsTheRetryAfterHintEvenWithAnErrorBody() async throws {
        let body = lastFMErrorResponse(code: 29).body
        let (adapter, _) = adapter([
            HTTPResponse(statusCode: 429, headers: ["Retry-After": "17"], body: body),
        ])

        await #expect(throws: ServiceFailure.rateLimited(retryAfter: 17)) {
            _ = try await adapter.submit(
                [lastFMTestListen()],
                connection: lastFMTestConnection(),
                credential: "session-key",
            )
        }
    }

    @Test func anUnparseableBatchIsRetryable() async throws {
        let malformedBodies = [
            Data("not json".utf8),
            Data(#"{"scrobbles":{}}"#.utf8),
            Data(#"{"scrobbles":{"scrobble":[]}}"#.utf8),
            Data(
                ##"{"scrobbles":{"scrobble":{"artist":{"#text":"Artist"},"track":{"#text":"Track"}}}}"##.utf8,
            ),
        ]

        for body in malformedBodies {
            let (adapter, _) = adapter([HTTPResponse(statusCode: 200, body: body)])
            await #expect(throws: ServiceFailure.retryable) {
                _ = try await adapter.submit(
                    [lastFMTestListen()],
                    connection: lastFMTestConnection(),
                    credential: "session-key",
                )
            }
        }
    }

    @Test func mapsIgnoredScrobbleCodes() async throws {
        let (adapter, _) = adapter([lastFMScrobbleResponse(codes: [0, 1, 2, 3, 4, 5])])
        let listens = (0 ..< 6).map { lastFMTestListen(index: $0) }

        let results = try await adapter.submit(
            listens,
            connection: lastFMTestConnection(),
            credential: "session-key",
        )

        #expect(results[0] == .delivered(reference: nil))
        for code in 1 ... 4 {
            #expect(results[code] == .rejected(reason: "Last.fm ignored this scrobble (code \(code))."))
        }
        #expect(results[5] == .rateLimited(retryAfter: nil))
    }
}
