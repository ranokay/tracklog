import Foundation
import Testing
@testable import TracklogCore

/// A HUD host, announcement recorder and refusal recorder wired through the
/// same public session the droplet uses.
@MainActor
final class HUDProbe {
    let host: RecordingHUDHost
    let session: HUDHostSession
    private let announcementLog: HUDTextLog
    private let refusalLog: HUDRefusalLog

    var announcements: [String] {
        announcementLog.values
    }

    var refusals: [HUDPresentation] {
        refusalLog.values
    }

    var presentations: [HUDPresentation] {
        host.presented
    }

    init(accepted: Bool = true) {
        let host = RecordingHUDHost(accepted: accepted)
        let announcements = HUDTextLog()
        let refusals = HUDRefusalLog()
        self.host = host
        announcementLog = announcements
        refusalLog = refusals
        session = HUDHostSession(
            host: host,
            announce: { announcements.values.append($0.spoken) },
            logRefusal: { refusals.values.append($0) },
        )
    }
}

@MainActor
final class HUDTextLog {
    var values: [String] = []
}

@MainActor
final class HUDRefusalLog {
    var values: [HUDPresentation] = []
}

@MainActor
func makeHUDRuntime(
    store: SQLiteListenStore,
    clock: FakeClock,
    probe: HUDProbe,
    adapters: [any DeliveryAdapter],
    credentials: any CredentialStore,
    source: ReplayedNowPlaying = ReplayedNowPlaying(),
) -> CaptureRuntime {
    CaptureRuntime(
        state: TracklogAppState(),
        clock: clock,
        source: source,
        store: store,
        allowlist: InMemoryAppAllowlist(),
        edits: store,
        blocks: store,
        credentials: credentials,
        serviceAdapters: adapters.map { $0 as any ServiceAdapter },
        hud: probe.session,
        settings: CaptureSettings(scrobblingEnabled: true),
    )
}

@MainActor
func saveHUDConnection(
    _ store: SQLiteListenStore,
    credentials: any CredentialStore,
    kind: ServiceKind,
    identity: String = "listener",
    base: Date,
    isEnabled: Bool = true,
    authState: ConnectionAuthState = .signedIn,
) async throws -> Connection {
    let connection = try await store.save(
        Connection(
            kind: kind,
            endpoint: kind.defaultEndpoint,
            identity: identity,
            isEnabled: isEnabled,
            authState: authState,
            createdAt: base,
        ),
    )
    try await credentials.saveCredential("token", forConnection: connection.id ?? -1)
    return connection
}

@MainActor
func insertHUDPending(
    _ store: SQLiteListenStore,
    connection: Connection,
    title: String,
    base: Date,
) async throws -> Listen {
    try #require(
        try await store.insert(
            deliveryListen(title: title, base: base),
            targets: [connection.id ?? -1],
        ),
    )
}

@MainActor
func insertHeldHUDPending(
    _ store: SQLiteListenStore,
    connection: Connection,
    title: String,
    start: TimeInterval,
    base: Date,
) async throws {
    let listen = try #require(
        try await store.insert(
            deliveryListen(title: title, base: base, start: start),
            targets: [connection.id ?? -1],
        ),
    )
    let delivery = try #require(try await store.deliveries(for: listen.id ?? -1).first)
    try await store.markFailed(
        delivery.id,
        attempts: 1,
        at: base,
        nextAttemptAt: base.addingTimeInterval(10 * 24 * 60 * 60),
        error: "The service could not be reached.",
    )
}
