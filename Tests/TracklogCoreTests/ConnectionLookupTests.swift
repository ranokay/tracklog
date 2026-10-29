import Foundation
import Testing
@testable import TracklogCore

@Suite("Connection lookup")
@MainActor
struct ConnectionLookupTests {
    private func connection(
        id: Int64,
        kind: ServiceKind = .libreFM,
        root: String,
    ) throws -> Connection {
        try Connection(
            id: id,
            kind: kind,
            endpoint: #require(ServiceEndpoint(normalizing: root)),
            identity: "listener",
            createdAt: Date(timeIntervalSince1970: 1_000_000),
        )
    }

    @Test func aNamedRootSelectsItsOwnConnection() throws {
        let state = TracklogAppState()
        state.connections = try [
            connection(id: 1, root: "https://one.example"),
            connection(id: 2, root: "https://two.example"),
        ]

        let second = try #require(ServiceEndpoint(normalizing: "https://two.example"))
        #expect(state.connection(kind: .libreFM, endpoint: second)?.id == 2)
    }

    @Test func anUnnamedRootFallsBackToTheFirstOfItsKind() throws {
        let state = TracklogAppState()
        state.connections = try [
            connection(id: 1, root: "https://one.example"),
            connection(id: 2, root: "https://two.example"),
            connection(id: 3, kind: .lastFM, root: "https://ws.audioscrobbler.com"),
        ]

        #expect(state.connection(kind: .libreFM)?.id == 1)
        #expect(state.connection(kind: .lastFM)?.id == 3)
        #expect(state.connection(kind: .listenBrainz) == nil)
    }

    @Test func aRootWithNoConnectionSelectsNothing() throws {
        let state = TracklogAppState()
        state.connections = try [connection(id: 1, root: "https://one.example")]

        let other = try #require(ServiceEndpoint(normalizing: "https://other.example"))
        #expect(state.connection(kind: .libreFM, endpoint: other) == nil)
    }
}
