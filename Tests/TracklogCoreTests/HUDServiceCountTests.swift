import Foundation
import Testing
@testable import TracklogCore

@Suite("HUD service counts")
@MainActor
struct HUDServiceCountTests: CaptureTestHelpers {
    @Test func distinctConnectionsWithTheSameVisibleLabelCountTwice() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let credentials = MemoryCredentialStore()
        let clock = FakeClock(base)
        let probe = HUDProbe()
        let adapter = RecordingDeliveryAdapter(kind: .libreFM)
        let firstEndpoint = try #require(
            ServiceEndpoint(normalizing: "https://music.example.com/one"),
        )
        let secondEndpoint = try #require(
            ServiceEndpoint(normalizing: "https://music.example.com/two"),
        )
        let first = try await saveHUDConnection(
            store,
            credentials: credentials,
            kind: .libreFM,
            endpoint: firstEndpoint,
            identity: "listener-one",
            base: base,
        )
        let second = try await saveHUDConnection(
            store,
            credentials: credentials,
            kind: .libreFM,
            endpoint: secondEndpoint,
            identity: "listener-two",
            base: base,
        )
        let runtime = makeHUDRuntime(
            store: store,
            clock: clock,
            probe: probe,
            adapters: [adapter],
            credentials: credentials,
        )
        await runtime.start()

        for connection in [first, second] {
            var updated = connection
            updated.authState = .needsSignIn
            _ = try await store.save(updated)
        }
        await runtime.reloadConnections()
        await eventually { probe.presentations.count == 1 }

        let card = try #require(probe.presentations.first)
        #expect(card.title == "2 services need sign-in")
        #expect(
            card.spoken
                == "music.example.com and music.example.com need sign-in. Scrobbles are waiting.",
        )
    }
}
