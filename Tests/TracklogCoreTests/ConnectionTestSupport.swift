import Foundation
@testable import TracklogCore

// MARK: - Connections

/// A scripted transport shared by the connection and adapter suites. Each
/// send takes the next answer and records the request it was handed.
actor ScriptedTransport: HTTPTransport {
    private enum Answer: Sendable {
        case response(HTTPResponse)
        case failure(URLError.Code)
    }

    private var answers: [Answer]
    private(set) var requests: [HTTPRequest] = []

    init(_ responses: [HTTPResponse]) {
        answers = responses.map { .response($0) }
    }

    init(error: URLError.Code) {
        answers = [.failure(error)]
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        guard !answers.isEmpty else { throw URLError(.unknown) }
        switch answers.removeFirst() {
        case let .response(response):
            return response
        case let .failure(code):
            throw URLError(code)
        }
    }
}

/// A successful ListenBrainz token-validation answer.
func listenBrainzValidResponse(user: String = "listener") -> HTTPResponse {
    HTTPResponse(
        statusCode: 200,
        body: Data(
            #"{"code":200,"message":"Token valid","valid":true,"user_name":"\#(user)"}"#.utf8,
        ),
    )
}

/// A credential store whose every write fails, to exercise link rollback.
struct FailingCredentialStore: CredentialStore {
    func credential(forConnection _: Int64) async throws -> String? {
        nil
    }

    func saveCredential(_: String, forConnection _: Int64) async throws {
        throw URLError(.cannotWriteToFile)
    }

    func deleteCredential(forConnection _: Int64) async throws {}

    func appCredential() async throws -> String? {
        nil
    }

    func saveAppCredential(_: String?) async throws {}
}

/// A service adapter with a fixed identity, for kinds whose real flow has not
/// landed yet.
struct StubAdapter: ServiceAdapter {
    let kind: ServiceKind
    let identity: ServiceIdentity
    let capabilities = ServiceCapabilities()

    func validate(_: String, endpoint _: ServiceEndpoint) async throws -> ServiceIdentity {
        identity
    }
}

/// A real store whose current-cursor write fails, to exercise link rollback.
actor CursorFailingStore: ConnectionStore {
    private let base: SQLiteListenStore

    init(_ base: SQLiteListenStore) {
        self.base = base
    }

    func connections() async throws -> [Connection] {
        try await base.connections()
    }

    func save(_ connection: Connection) async throws -> Connection {
        try await base.save(connection)
    }

    func deleteConnection(id: Int64) async throws {
        try await base.deleteConnection(id: id)
    }

    func currentConnectionID() async throws -> Int64? {
        try await base.currentConnectionID()
    }

    func setCurrentConnectionID(_: Int64?) async throws {
        throw DatabaseError.unavailable("simulated current-cursor failure")
    }
}

/// A real store whose deletion fails a fixed number of times, to exercise the
/// repair of a credentialless row left by a failed link.
actor CleanupFailingStore: ConnectionStore {
    private let base: SQLiteListenStore
    private var deletesToFail: Int

    init(_ base: SQLiteListenStore, deletesToFail: Int = 1) {
        self.base = base
        self.deletesToFail = deletesToFail
    }

    func connections() async throws -> [Connection] {
        try await base.connections()
    }

    func save(_ connection: Connection) async throws -> Connection {
        try await base.save(connection)
    }

    func deleteConnection(id: Int64) async throws {
        guard deletesToFail == 0 else {
            deletesToFail -= 1
            throw DatabaseError.unavailable("simulated cleanup failure")
        }
        try await base.deleteConnection(id: id)
    }

    func currentConnectionID() async throws -> Int64? {
        try await base.currentConnectionID()
    }

    func setCurrentConnectionID(_ id: Int64?) async throws {
        try await base.setCurrentConnectionID(id)
    }
}

/// A real store whose current-cursor write and connection deletion both fail
/// once, to exercise the recovery path that keeps a saved connection visible.
actor RecoveryFailingStore: ConnectionStore, ListenStore { private let base: SQLiteListenStore
    private var currentWritesToFail: Int
    private var deletesToFail: Int

    init(
        _ base: SQLiteListenStore,
        currentWritesToFail: Int = 1,
        deletesToFail: Int = 1,
    ) {
        self.base = base
        self.currentWritesToFail = currentWritesToFail
        self.deletesToFail = deletesToFail
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

    func connections() async throws -> [Connection] {
        try await base.connections()
    }

    func save(_ connection: Connection) async throws -> Connection {
        try await base.save(connection)
    }

    func deleteConnection(id: Int64) async throws {
        guard deletesToFail == 0 else {
            deletesToFail -= 1
            throw DatabaseError.unavailable("simulated cleanup failure")
        }
        try await base.deleteConnection(id: id)
    }

    func currentConnectionID() async throws -> Int64? {
        try await base.currentConnectionID()
    }

    func setCurrentConnectionID(_ id: Int64?) async throws {
        guard currentWritesToFail == 0 else {
            currentWritesToFail -= 1
            throw DatabaseError.unavailable("simulated current-cursor failure")
        }
        try await base.setCurrentConnectionID(id)
    }
}

/// A real store whose first connection read fails, to exercise a failed load
/// followed by an unrelated failed operation.
actor LoadFailingStore: ConnectionStore, ListenStore {
    private let base: SQLiteListenStore
    private var connectionReads = 0

    init(_ base: SQLiteListenStore) {
        self.base = base
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

    func connections() async throws -> [Connection] {
        connectionReads += 1
        guard connectionReads > 1 else {
            throw DatabaseError.unavailable("simulated connection read failure")
        }
        return try await base.connections()
    }

    func save(_ connection: Connection) async throws -> Connection {
        try await base.save(connection)
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

/// A memory credential store whose save suspends, to prove a load cannot
/// interleave with a link after the row is saved but before the credential is.
actor SuspendingCredentialStore: CredentialStore {
    private let base = MemoryCredentialStore()
    private var saveContinuation: CheckedContinuation<Void, Never>?
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var didStartSaving = false

    func credential(forConnection id: Int64) async throws -> String? {
        try await base.credential(forConnection: id)
    }

    func saveCredential(_ credential: String, forConnection id: Int64) async throws {
        didStartSaving = true
        startedContinuation?.resume()
        startedContinuation = nil
        await withCheckedContinuation { saveContinuation = $0 }
        try await base.saveCredential(credential, forConnection: id)
    }

    func deleteCredential(forConnection id: Int64) async throws {
        try await base.deleteCredential(forConnection: id)
    }

    func appCredential() async throws -> String? {
        try await base.appCredential()
    }

    func saveAppCredential(_ credential: String?) async throws {
        try await base.saveAppCredential(credential)
    }

    func waitUntilSaving() async {
        guard !didStartSaving else { return }
        await withCheckedContinuation { startedContinuation = $0 }
    }

    func resumeSaving() {
        saveContinuation?.resume()
        saveContinuation = nil
    }
}

/// A memory credential store whose deletion fails a fixed number of times, to
/// exercise the recovery path that keeps a connection with its credential.
actor DeleteFailingCredentialStore: CredentialStore {
    private let base = MemoryCredentialStore()
    private var deletesToFail: Int

    init(deletesToFail: Int = 1) {
        self.deletesToFail = deletesToFail
    }

    func credential(forConnection id: Int64) async throws -> String? {
        try await base.credential(forConnection: id)
    }

    func saveCredential(_ credential: String, forConnection id: Int64) async throws {
        try await base.saveCredential(credential, forConnection: id)
    }

    func deleteCredential(forConnection id: Int64) async throws {
        guard deletesToFail == 0 else {
            deletesToFail -= 1
            throw DatabaseError.unavailable("simulated credential deletion failure")
        }
        try await base.deleteCredential(forConnection: id)
    }

    func appCredential() async throws -> String? {
        try await base.appCredential()
    }

    func saveAppCredential(_ credential: String?) async throws {
        try await base.saveAppCredential(credential)
    }
}
