import Foundation
import Testing
@testable import TracklogCore

/// Collects the lines the adapter sends to its diagnostics sink. The sink is
/// a synchronous closure, so the storage is locked rather than actor-isolated.
private final class LogSink: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    func append(_ line: String) {
        lock.withLock { stored.append(line) }
    }

    var lines: [String] {
        lock.withLock { stored }
    }
}

@Suite("Last.fm entity answer diagnostics")
struct LastFMEntityDiagnosticsTests {
    // Sentinels that must never reach the diagnostic line.
    private static let apiKey = "KEYSECRETAAA"
    private static let sharedSecret = "SHAREDSECRETBBB"
    private static let username = "USERNAMECCC"
    private static let bodyValue = "BODYVALUEDDD"

    private struct Outcome {
        let lines: [String]
        let request: HTTPRequest
        let failure: EntityServiceFailure?
    }

    private func run(_ response: HTTPResponse) async throws -> Outcome {
        let transport = ScriptedTransport([response])
        let sink = LogSink()
        let adapter = LastFMAdapter(
            transport: transport,
            appCredentials: LastFMAppCredentials(apiKey: Self.apiKey, sharedSecret: Self.sharedSecret),
            entityDiagnostics: { sink.append($0) },
        )
        let request = try #require(EntityRequest.track(title: "DRIP", artist: "BABYMONSTER"))
        let connection = Connection(
            kind: .lastFM,
            endpoint: .lastFM,
            identity: Self.username,
            createdAt: Date(),
        )
        var failure: EntityServiceFailure?
        do {
            _ = try await adapter.entityDetails(request, connection: connection)
        } catch let thrown as EntityServiceFailure {
            failure = thrown
        }
        let sent = try #require(await transport.requests.first)
        return Outcome(lines: sink.lines, request: sent, failure: failure)
    }

    private func jsonHeaders() -> [String: String] {
        ["Content-Type": "application/json; charset=utf-8"]
    }

    @Test func aTopLevelArrayLogsTheDecodingFailureWithoutItsValues() async throws {
        let body = Data(#"[{"track":"\#(Self.bodyValue)"}]"#.utf8)
        let outcome = try await run(HTTPResponse(statusCode: 200, headers: jsonHeaders(), body: body))

        #expect(outcome.failure == .unreadable)
        let expected = [
            "Last.fm track.getInfo answer unreadable:",
            "status=200 bytes=\(body.count) content-type=application/json json=yes",
            "keys=none entity=absent decode=typeMismatch@root empty-entity=no",
        ].joined(separator: " ")
        #expect(outcome.lines == [expected])
    }

    @Test func anEntityThatIsNotAnObjectLogsItsShapeAndNoValue() async throws {
        let outcome = try await run(HTTPResponse(
            statusCode: 200,
            headers: jsonHeaders(),
            body: Data(#"{"track":"\#(Self.bodyValue)"}"#.utf8),
        ))

        #expect(outcome.failure == .unreadable)
        let line = try #require(outcome.lines.first)
        #expect(outcome.lines.count == 1)
        #expect(line.contains("keys=track"))
        #expect(line.contains("entity=string"))
        #expect(line.contains("decode=ok"))
        #expect(line.contains("empty-entity=no"))
    }

    @Test func anEmptyEntityObjectLogsThatTheEmptyCheckRejectedIt() async throws {
        let outcome = try await run(HTTPResponse(
            statusCode: 200,
            headers: jsonHeaders(),
            body: Data(#"{"track":{"foo":"\#(Self.bodyValue)"}}"#.utf8),
        ))

        #expect(outcome.failure == .unreadable)
        let line = try #require(outcome.lines.first)
        #expect(outcome.lines.count == 1)
        #expect(line.contains("keys=track"))
        #expect(line.contains("entity=object"))
        #expect(line.contains("decode=ok"))
        #expect(line.contains("empty-entity=yes"))
    }

    @Test func aNonJSONBodyLogsItsMediaTypeAndTheCharsetIsNotKept() async throws {
        let outcome = try await run(HTTPResponse(
            statusCode: 200,
            headers: ["Content-Type": "text/html; charset=utf-8"],
            body: Data("<html>\(Self.bodyValue)</html>".utf8),
        ))

        #expect(outcome.failure == .unreadable)
        let line = try #require(outcome.lines.first)
        #expect(line.contains("content-type=text/html "))
        #expect(!line.contains("charset"))
        #expect(line.contains("json=no"))
        #expect(line.contains("decode=dataCorrupted@root"))
    }

    @Test func theLineNeverCarriesASecretOrAValueFromTheAnswer() async throws {
        let scenarios = [
            HTTPResponse(statusCode: 200, headers: jsonHeaders(), body: Data(#"[{"track":"\#(Self.bodyValue)"}]"#.utf8)),
            HTTPResponse(statusCode: 200, headers: jsonHeaders(), body: Data(#"{"track":"\#(Self.bodyValue)"}"#.utf8)),
            HTTPResponse(statusCode: 200, headers: jsonHeaders(), body: Data(#"{"track":{"foo":"\#(Self.bodyValue)"}}"#.utf8)),
            HTTPResponse(statusCode: 200, headers: [:], body: Data("<html>\(Self.bodyValue)</html>".utf8)),
        ]
        for response in scenarios {
            let outcome = try await run(response)
            let line = try #require(outcome.lines.first)
            let signature = formParameters(outcome.request)["api_sig"] ?? ""
            #expect(!signature.isEmpty)
            for secret in [Self.apiKey, Self.sharedSecret, Self.username, Self.bodyValue, signature] {
                #expect(!line.contains(secret), "The diagnostic line contains a protected value.")
            }
            #expect(!line.contains("https://"))
            #expect(!line.contains("api_key"))
            #expect(!line.contains("ws.audioscrobbler"))
        }
    }

    @Test func aReadableAnswerLogsNothing() async throws {
        let outcome = try await run(HTTPResponse(
            statusCode: 200,
            headers: jsonHeaders(),
            body: Data(#"{"track":{"name":"DRIP","url":"https://www.last.fm/music/BABYMONSTER/_/DRIP","listeners":"12"}}"#.utf8),
        ))

        #expect(outcome.failure == nil)
        #expect(outcome.lines.isEmpty)
    }
}
