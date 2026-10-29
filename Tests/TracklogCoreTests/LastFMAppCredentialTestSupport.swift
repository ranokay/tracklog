import Foundation
import Testing
@testable import TracklogCore

struct Harness {
    let database: TemporaryDatabase
    let store: SQLiteListenStore
    let credentials: MemoryCredentialStore
    let transport: ScriptedTransport
    let state: TracklogAppState
    let runtime: CaptureRuntime
}

struct UnreadableAppCredentialStore: CredentialStore {
    func credential(forConnection _: Int64) async throws -> String? {
        nil
    }

    func saveCredential(_: String, forConnection _: Int64) async throws {}

    func deleteCredential(forConnection _: Int64) async throws {}

    func appCredential() async throws -> String? {
        throw URLError(.cannotDecodeContentData)
    }

    func saveAppCredential(_: String?) async throws {}
}

/// A memory credential store whose application-slot write always fails, so
/// the pre-write invalidation marker can be observed.
actor SaveFailingAppCredentialStore: CredentialStore {
    private let base = MemoryCredentialStore()

    func credential(forConnection id: Int64) async throws -> String? {
        try await base.credential(forConnection: id)
    }

    func saveCredential(_ credential: String, forConnection id: Int64) async throws {
        try await base.saveCredential(credential, forConnection: id)
    }

    func deleteCredential(forConnection id: Int64) async throws {
        try await base.deleteCredential(forConnection: id)
    }

    func appCredential() async throws -> String? {
        try await base.appCredential()
    }

    func saveAppCredential(_: String?) async throws {
        throw URLError(.cannotWriteToFile)
    }
}

/// A real store whose first needs-sign-in write fails, so the invalidation
/// repair path can be exercised without a second database.
actor SignOutFailingStore: ListenStore, ConnectionStore {
    private let base: SQLiteListenStore
    private var failuresLeft: Int

    init(_ base: SQLiteListenStore, failuresLeft: Int = 1) {
        self.base = base
        self.failuresLeft = failuresLeft
    }

    func insert(_ listen: Listen) async throws -> Listen? {
        try await base.insert(listen)
    }

    func page(limit: Int, before cursor: ListenCursor?) async throws -> [Listen] {
        try await base.page(limit: limit, before: cursor)
    }

    func count() async throws -> Int {
        try await base.count()
    }

    func count(in range: Range<Date>) async throws -> Int {
        try await base.count(in: range)
    }

    func connections() async throws -> [Connection] {
        try await base.connections()
    }

    func save(_ connection: Connection) async throws -> Connection {
        if connection.authState == .needsSignIn, failuresLeft > 0 {
            failuresLeft -= 1
            throw DatabaseError.unavailable("simulated sign-out failure")
        }
        return try await base.save(connection)
    }

    func deleteConnection(id: Int64) async throws {
        try await base.deleteConnection(id: id)
    }

    func currentConnectionID() async throws -> Int64? {
        try await base.currentConnectionID()
    }

    func setCurrentConnectionID(_ id: Int64?) async throws {
        try await base.setCurrentConnectionID(id)
    }
}

let lastFMAppCredentialBase = Date(timeIntervalSince1970: 1_000_000)

@MainActor
func makeHarness(
    transport: ScriptedTransport,
    credentials: MemoryCredentialStore = MemoryCredentialStore(),
    compiled: LastFMAppCredentials = lastFMTestCredentials,
    appCredentialProblem: AppCredentialProblem? = nil,
    persistAppCredentialProblem: (@MainActor (AppCredentialProblem?) -> Void)? = nil,
) async throws -> Harness {
    let database = try TemporaryDatabase()
    let store = try SQLiteListenStore(url: database.url)
    let clock = FakeClock(lastFMAppCredentialBase)
    let state = TracklogAppState()
    let adapter = LastFMAdapter(
        transport: transport,
        appCredentials: StoredLastFMAppCredentials(
            credentialStore: credentials,
            compiled: compiled,
        ),
    )
    let runtime = CaptureRuntime(
        state: state,
        clock: clock,
        source: ReplayedNowPlaying(),
        store: store,
        allowlist: InMemoryAppAllowlist(),
        credentials: credentials,
        serviceAdapters: [adapter],
        compiledLastFMAppCredentials: compiled,
        settings: CaptureSettings(scrobblingEnabled: false),
        appCredentialProblem: appCredentialProblem,
        persistAppCredentialProblem: persistAppCredentialProblem,
    )
    await runtime.start()
    return Harness(
        database: database,
        store: store,
        credentials: credentials,
        transport: transport,
        state: state,
        runtime: runtime,
    )
}

@MainActor
@discardableResult
func link(_ harness: Harness, credential: String = "session-key") async throws -> Connection {
    try await harness.runtime.linkVerified(
        kind: .lastFM,
        credential: credential,
        identity: ServiceIdentity(name: "listener"),
    )
}
