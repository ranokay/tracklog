import Foundation
import Testing
@testable import TracklogCore

/// Every line the adapter's diagnostics sink receives during one read.
private final class DiagnosticLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    func append(_ line: String) {
        lock.withLock { stored.append(line) }
    }

    var lines: [String] {
        lock.withLock { stored }
    }
}

private func facts(_ service: EntityServiceSection?) -> [EntityFact] {
    if case let .facts(served) = service {
        return served.facts
    }
    return []
}

/// The query of a GET request as name-to-value pairs.
private func query(_ request: HTTPRequest) -> [String: String] {
    let items = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    return items.reduce(into: [:]) { $0[$1.name] = $1.value ?? "" }
}

@Suite("Last.fm entity reads")
@MainActor
struct EntityGetCompositionTests {
    private func artistRequest() throws -> EntityRequest {
        try #require(EntityRequest.artist(name: "Blondie"))
    }

    private func albumRequest() throws -> EntityRequest {
        try #require(EntityRequest.album(album: "Parallel Lines", artist: "Blondie"))
    }

    private func trackRequest() throws -> EntityRequest {
        try #require(EntityRequest.track(title: "Heart of Glass", artist: "Blondie"))
    }

    /// Seeds the local history, links the account under `identity`, opens the
    /// page and waits for its service section to leave loading.
    private func openEntity(
        _ composition: EntityTestComposition,
        request: EntityRequest,
        identity: String = "listener",
    ) async throws -> EntityServiceSection {
        try await seedEntityHistory(composition.store)
        _ = try await composition.runtime.linkVerified(
            kind: .lastFM,
            credential: "session",
            identity: ServiceIdentity(name: identity),
        )
        try await composition.runtime.openEntityDetail(request)
        #expect(await waitForEntityService(composition.state) { $0 != .loading })
        return try #require(composition.state.entityDetail?.service)
    }

    private func lastFMRequests(_ composition: EntityTestComposition) async -> [HTTPRequest] {
        await composition.transport.requests(toHost: "ws.audioscrobbler.com")
    }

    /// The one request an entity read sends: a signed GET with the username,
    /// no session key, and the method named by the page.
    private func expectOneSignedGet(
        _ sent: [HTTPRequest],
        method: String,
    ) throws -> HTTPRequest {
        #expect(sent.count == 1)
        let request = try #require(sent.first)
        #expect(request.method == .get)
        #expect(request.body == nil)
        let parameters = query(request)
        #expect(parameters["method"] == method)
        #expect(parameters["username"] == "listener")
        #expect(parameters["sk"] == nil)
        #expect(parameters["api_sig"]?.isEmpty == false)
        return request
    }

    @Test func theArtistPageIsOneSignedGetAndRendersItsFacts() async throws {
        let composition = try await entityComposition { request in
            formParameters(request)["method"] == "artist.getInfo"
                ? entityLastFMArtistInfo(userPlays: 3)
                : HTTPResponse(statusCode: 404, body: Data())
        }

        let service = try await openEntity(composition, request: artistRequest())

        _ = try await expectOneSignedGet(lastFMRequests(composition), method: "artist.getInfo")
        #expect(facts(service).contains { $0.label == "Listeners on Last.fm" })
        #expect(facts(service).contains { $0.label == "Your plays" && $0.value == "3" })
    }

    @Test func theAlbumPageIsOneSignedGetAndRendersItsFacts() async throws {
        let composition = try await entityComposition { request in
            formParameters(request)["method"] == "album.getInfo"
                ? entityLastFMAlbumInfo(userPlays: 7)
                : HTTPResponse(statusCode: 404, body: Data())
        }

        let service = try await openEntity(composition, request: albumRequest())

        _ = try await expectOneSignedGet(lastFMRequests(composition), method: "album.getInfo")
        #expect(facts(service).contains { $0.label == "Your plays" && $0.value == "7" })
    }

    @Test func theTrackPageIsOneSignedGetAndRendersItsFacts() async throws {
        let composition = try await entityComposition { request in
            formParameters(request)["method"] == "track.getInfo"
                ? entityLastFMTrackInfo(userPlays: 9)
                : HTTPResponse(statusCode: 404, body: Data())
        }

        let service = try await openEntity(composition, request: trackRequest())

        _ = try await expectOneSignedGet(lastFMRequests(composition), method: "track.getInfo")
        #expect(facts(service).contains { $0.label == "Your plays" && $0.value == "9" })
    }

    @Test func anEmptyObjectIsNotRetriedAndShowsUnreadable() async throws {
        let log = DiagnosticLog()
        let composition = try await entityComposition(
            entityDiagnostics: { log.append($0) },
            handler: { _ in HTTPResponse(statusCode: 200, body: Data("{}".utf8)) },
        )

        let service = try await openEntity(composition, request: trackRequest())

        #expect(service == .failed(.unreadable))
        let request = try await expectOneSignedGet(lastFMRequests(composition), method: "track.getInfo")
        #expect(log.lines.count == 1)
        let line = try #require(log.lines.first)
        #expect(line.hasPrefix("Last.fm track.getInfo answer unreadable:"))
        #expect(line.contains("entity=absent"))
        #expect(line.hasSuffix("empty-entity=no"))
        // The line names no value, key, signature, username or URL.
        let signature = query(request)["api_sig"] ?? ""
        for secret in [request.url.absoluteString, signature, "api-key", "secret", "listener", "Heart of Glass", "Blondie", "https://"] {
            #expect(!line.contains(secret), "The diagnostic line contains a protected value.")
        }
    }

    @Test func aTimedOutReadMakesOneRequestAndShowsTimedOut() async throws {
        let composition = try await entityComposition(timeout: 0.05) { _ in
            // Answer after the page timeout, so the read is cut short.
            Thread.sleep(forTimeInterval: 0.3)
            return entityLastFMTrackInfo(userPlays: 9)
        }

        let service = try await openEntity(composition, request: trackRequest())

        #expect(service == .failed(.timedOut))
        #expect(await lastFMRequests(composition).count == 1)
    }

    @Test func aGetCarriesEveryCharacterIntactAndASignatureOverItsParameters() async throws {
        // Spaces, `&`, `+`, `=`, `#`, `/` and non-ASCII text in both names.
        let title = "Rock & Roll + Blues = #1 / Mötley 日本"
        let artist = "Mötley & Crüe + 日本 = #2 / Blues"
        let request = try #require(EntityRequest.track(title: title, artist: artist))
        let composition = try await entityComposition { entityRequest in
            formParameters(entityRequest)["method"] == "track.getInfo"
                ? entityLastFMTrackInfo(userPlays: 9)
                : HTTPResponse(statusCode: 404, body: Data())
        }

        _ = try await openEntity(composition, request: request)

        let get = try await expectOneSignedGet(lastFMRequests(composition), method: "track.getInfo")
        let values = query(get)
        #expect(values["track"] == title)
        #expect(values["artist"] == artist)

        // The signature in the query is the one computed over the same
        // parameters, without the signature itself.
        let signature = try #require(values["api_sig"])
        var signed = values
        signed["api_sig"] = nil
        #expect(signature == LastFMSignature.signature(parameters: signed, sharedSecret: "secret"))
    }

    @Test func everyOtherLastFMCallStaysAPost() async {
        let transport = ScriptedTransport([
            lastFMTokenResponse(),
            lastFMSessionResponse(),
            lastFMUserResponse(),
            lastFMEmptyResponse(),
            lastFMEmptyResponse(),
            lastFMEmptyResponse(),
            lastFMEmptyResponse(),
        ])
        let client = LastFMClient(transport: transport, appCredentials: lastFMTestCredentials)

        _ = try? await client.requestToken()
        _ = try? await client.session(token: "request-token")
        _ = try? await client.userIdentity(sessionKey: "session")
        _ = try? await client.accountPlaycount(user: "listener")
        _ = try? await client.topChart(type: .artists, user: "listener", period: .week, limit: 5)
        try? await client.updateNowPlaying(lastFMTestTrack(), sessionKey: "session")
        _ = try? await client.scrobble([lastFMTestListen()], sessionKey: "session")

        let sent = await transport.requests
        #expect(sent.map { formParameters($0)["method"] ?? "" } == [
            "auth.getToken",
            "auth.getSession",
            "user.getInfo",
            "user.getInfo",
            "user.getTopArtists",
            "track.updateNowPlaying",
            "track.scrobble",
        ])
        #expect(sent.allSatisfy { $0.method == .post })
    }
}
