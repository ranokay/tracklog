import Foundation
import Testing
@testable import TracklogCore

let connectionLifecycleBase = Date(timeIntervalSince1970: 1_000_000)

@MainActor
func makeConnectionRuntime(
    store: SQLiteListenStore,
    credentials: any CredentialStore,
    adapters: [any DeliveryAdapter],
    state: TracklogAppState = TracklogAppState(),
) -> CaptureRuntime {
    CaptureRuntime(
        state: state,
        clock: FakeClock(connectionLifecycleBase),
        source: ReplayedNowPlaying(),
        store: store,
        allowlist: InMemoryAppAllowlist(),
        credentials: credentials,
        serviceAdapters: adapters.map { $0 as any ServiceAdapter },
        settings: CaptureSettings(scrobblingEnabled: true),
    )
}

@MainActor
func savedConnection(
    _ store: SQLiteListenStore,
    kind: ServiceKind = .listenBrainz,
    identity: String = "listener",
    authState: ConnectionAuthState = .needsSignIn,
    lastUsedAt: Date? = nil,
) async throws -> Connection {
    try await store.save(
        Connection(
            kind: kind,
            endpoint: kind.defaultEndpoint,
            identity: identity,
            authState: authState,
            createdAt: connectionLifecycleBase,
            lastUsedAt: lastUsedAt,
        ),
    )
}

@MainActor
func holdPendingDelivery(
    _ store: SQLiteListenStore,
    connection: Connection,
    title: String = "One",
    attemptIn seconds: TimeInterval = 3600,
) async throws -> Listen {
    let listen = try #require(
        try await store.insert(
            deliveryListen(title: title, base: connectionLifecycleBase),
            targets: [connection.id ?? -1],
        ),
    )
    let delivery = try #require(try await store.deliveries(for: listen.id ?? -1).first)
    try await store.markFailed(
        delivery.id,
        attempts: 1,
        at: connectionLifecycleBase,
        nextAttemptAt: connectionLifecycleBase.addingTimeInterval(seconds),
        error: "offline",
    )
    return listen
}

final class ConnectionConfirmation {
    private(set) var pending: [Int] = []
    private(set) var existingIdentity: [String] = []
    private(set) var newIdentity: [String] = []

    func record(existing: Connection, identity: ServiceIdentity, pending: Int) {
        self.pending.append(pending)
        existingIdentity.append(existing.identity)
        newIdentity.append(identity.name)
    }
}
