import Foundation
import Testing
@testable import TracklogCore

@Suite("HUD sign-in recovery")
@MainActor
struct HUDSignInRecoveryTests: CaptureTestHelpers {
    @Test func aRenewedAuthFailureInvalidatesThePendingRecovery() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let credentials = MemoryCredentialStore()
        let clock = FakeClock(base)
        let probe = HUDProbe()
        let adapter = RecordingDeliveryAdapter(kind: .lastFM, answers: [.failure(.auth)])
        let connection = try await saveHUDConnection(
            store,
            credentials: credentials,
            kind: .lastFM,
            base: base,
            authState: .needsSignIn,
        )
        try await credentials.saveCredential("old-token", forConnection: connection.id ?? -1)
        _ = try await insertHUDPending(store, connection: connection, title: "Held", base: base)

        let runtime = makeHUDRuntime(
            store: store,
            clock: clock,
            probe: probe,
            adapters: [adapter],
            credentials: credentials,
        )
        await runtime.start()
        #expect(probe.presentations.isEmpty)

        _ = try await runtime.reauthenticate(
            id: connection.id ?? -1,
            credential: "new-token",
            identity: ServiceIdentity(name: "listener"),
            confirmReplacement: { _, _, _ in false },
        )
        await eventually { runtime.state.connection(id: connection.id ?? -1)?.authState == .needsSignIn }
        #expect(probe.presentations.contains { $0.id == "hud.failure.signin" })

        let pending = try #require(try await store.pendingDeliveries().first)
        await runtime.deleteDelivery(pending.delivery)
        await turnMainActor(50)

        #expect(
            !probe.presentations.contains { $0.id == "hud.recovery.signin" },
            "a rejected re-auth cannot announce reconnection after its queue is gone",
        )
    }

    @Test func aDifferentIdentityCannotInheritThePendingRecovery() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let credentials = MemoryCredentialStore()
        let clock = FakeClock(base)
        let probe = HUDProbe()
        let adapter = RecordingDeliveryAdapter(
            kind: .lastFM,
            answers: [.failure(.rateLimited(retryAfter: 120))],
        )
        let connection = try await saveHUDConnection(
            store,
            credentials: credentials,
            kind: .lastFM,
            base: base,
            authState: .needsSignIn,
        )
        try await credentials.saveCredential("old-token", forConnection: connection.id ?? -1)
        _ = try await insertHUDPending(store, connection: connection, title: "Held", base: base)

        let runtime = makeHUDRuntime(
            store: store,
            clock: clock,
            probe: probe,
            adapters: [adapter],
            credentials: credentials,
        )
        await runtime.start()

        _ = try await runtime.reauthenticate(
            id: connection.id ?? -1,
            credential: "new-token",
            identity: ServiceIdentity(name: "listener"),
            confirmReplacement: { _, _, _ in false },
        )
        await eventually {
            runtime.state.connection(id: connection.id ?? -1)?.authState == .signedIn
                && runtime.state.pendingQueue.count == 1
        }

        _ = try await runtime.reauthenticate(
            id: connection.id ?? -1,
            credential: "other-token",
            identity: ServiceIdentity(name: "other-listener"),
            confirmReplacement: { _, _, _ in true },
        )
        await eventually {
            runtime.state.connection(id: connection.id ?? -1)?.identity == "other-listener"
        }
        await turnMainActor(50)

        #expect(
            !probe.presentations.contains { $0.id == "hud.recovery.signin" },
            "the replacement identity must not inherit the old account's recovery",
        )
    }

    @Test func signedInRecoveryReportsTheDeliveredCount() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let credentials = MemoryCredentialStore()
        let clock = FakeClock(base)
        let probe = HUDProbe()
        let adapter = RecordingDeliveryAdapter(kind: .lastFM)
        let connection = try await saveHUDConnection(
            store,
            credentials: credentials,
            kind: .lastFM,
            base: base,
            authState: .needsSignIn,
        )
        try await credentials.saveCredential("old-token", forConnection: connection.id ?? -1)
        _ = try await insertHUDPending(
            store,
            connection: connection,
            title: "Held",
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
        #expect(probe.presentations.isEmpty)

        _ = try await runtime.reauthenticate(
            id: connection.id ?? -1,
            credential: "new-token",
            identity: ServiceIdentity(name: "listener"),
            confirmReplacement: { _, _, _ in false },
        )
        await eventually { probe.presentations.count == 1 }

        let recovery = try #require(probe.presentations.first)
        #expect(recovery.id == "hud.recovery.signin")
        #expect(recovery.spoken == "Last.fm reconnected. 1 scrobble sent.")
        #expect(recovery.priority == .low)
        #expect(probe.announcements == [recovery.spoken])
    }
}
