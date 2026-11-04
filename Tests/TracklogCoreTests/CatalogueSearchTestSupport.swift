// swiftlint:disable large_tuple
import Foundation
@testable import TracklogCore

/// A controlled Last.fm transport for the catalogue suites. It answers by
/// method and parameters, records every outbound request, counts how many are
/// inside at once, and can hold chosen requests open until the test releases
/// them.
actor CatalogueTransport: HTTPTransport {
    typealias Handler = @Sendable ([String: String]) throws -> HTTPResponse

    private let handler: Handler
    private let hold: @Sendable ([String: String]) -> Bool
    private var released = false
    private var held: [CheckedContinuation<Void, Never>] = []
    private var entered = 0
    private(set) var requests: [HTTPRequest] = []
    private var inFlight = 0
    private(set) var maxInFlight = 0

    init(
        hold: @escaping @Sendable ([String: String]) -> Bool = { _ in false },
        handler: @escaping Handler,
    ) {
        self.hold = hold
        self.handler = handler
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
        defer { inFlight -= 1 }

        let parameters = formParameters(request)
        if hold(parameters) {
            entered += 1
            if !released {
                await withCheckedContinuation { held.append($0) }
            }
        }
        return try handler(parameters)
    }

    func release() {
        released = true
        let waiters = held
        held.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func requestCount() -> Int {
        requests.count
    }

    func methods() -> [String] {
        requests.compactMap { formParameters($0)["method"] }
    }

    func parameters() -> [[String: String]] {
        requests.map(formParameters)
    }

    func maxConcurrentRequests() -> Int {
        maxInFlight
    }

    func waitUntilEntered(_ count: Int, timeout: Duration = .seconds(3)) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while entered < count {
            if ContinuousClock.now >= deadline {
                return false
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }
}

// MARK: - Responses

private func catalogueJSON(_ text: String) -> HTTPResponse {
    HTTPResponse(statusCode: 200, body: Data(text.utf8))
}

private func entry(_ name: String, url: String?) -> String {
    let link = url.map { #""url":"\#($0)","# } ?? #""url":"","#
    return #"{"name":"\#(name)",\#(link)"mbid":""}"#
}

func artistSearchResponse(_ entries: [(name: String, url: String?)]) -> HTTPResponse {
    let rows = entries.map { entry($0.name, url: $0.url) }.joined(separator: ",")
    return catalogueJSON(#"{"results":{"artistmatches":{"artist":[\#(rows)]}}}"#)
}

func albumSearchResponse(_ entries: [(name: String, artist: String, url: String?)]) -> HTTPResponse {
    let rows = entries.map { value -> String in
        let link = value.url.map { #""url":"\#($0)","# } ?? #""url":"","#
        return #"{"name":"\#(value.name)","artist":"\#(value.artist)",\#(link)"mbid":""}"#
    }.joined(separator: ",")
    return catalogueJSON(#"{"results":{"albummatches":{"album":[\#(rows)]}}}"#)
}

func trackSearchResponse(_ entries: [(name: String, artist: String, url: String?)]) -> HTTPResponse {
    let rows = entries.map { value -> String in
        let link = value.url.map { #""url":"\#($0)","# } ?? #""url":"","#
        return #"{"name":"\#(value.name)","artist":"\#(value.artist)",\#(link)}"#
    }.joined(separator: ",")
    return catalogueJSON(#"{"results":{"trackmatches":{"track":[\#(rows)]}}}"#)
}

func lovedTracksResponse(
    _ entries: [(title: String, artist: String, url: String?)],
    page: Int,
    totalPages: Int,
) -> HTTPResponse {
    let rows = entries.map { value -> String in
        let link = value.url.map { #""url":"\#($0)","# } ?? #""url":"","#
        return #"{"name":"\#(value.title)","artist":{"name":"\#(value.artist)"},\#(link)"mbid":""}"#
    }.joined(separator: ",")
    return catalogueJSON(
        #"{"lovedtracks":{"track":[\#(rows)],"@attr":{"page":"\#(page)","perPage":"200","totalPages":"\#(totalPages)"}}}"#,
    )
}

func oneTrack(_ title: String, artist: String) -> [(name: String, artist: String, url: String?)] {
    [(name: title, artist: artist, url: "https://www.last.fm/music/\(artist)/_/\(title)")]
}

func oneArtist(_ name: String) -> [(name: String, url: String?)] {
    [(name: name, url: "https://www.last.fm/music/\(name)")]
}

func oneAlbum(_ name: String, artist: String) -> [(name: String, artist: String, url: String?)] {
    [(name: name, artist: artist, url: "https://www.last.fm/music/\(artist)/\(name)")]
}

// MARK: - Waiting

@MainActor
func catalogueWaitUntil(
    timeout: Duration = .seconds(3),
    _ condition: @MainActor () -> Bool,
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !condition() {
        if ContinuousClock.now >= deadline {
            return false
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}

@MainActor
func speakDebounce(_ clock: FakeClock, _ model: CatalogueSearchReadModel, _ query: String) async {
    model.updateQuery(query)
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while clock.sleeperCount == 0, ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(5))
    }
    clock.advance(to: clock.now.addingTimeInterval(CatalogueSearchReadModel.debounce))
}

// swiftlint:enable large_tuple
