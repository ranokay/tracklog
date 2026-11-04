import Foundation
import TracklogCore

/// Deterministic Loved states for the harness. The readers never touch the
/// network; every row is synthetic.
enum HarnessLovedFixture: String {
    case normal
    case loading
    case empty
    case failed
    case unsupported
    case appCredentials = "app-credentials"
    case longNames = "long-names"
    case noConnection = "no-connection"
    case needsSignIn = "needs-sign-in"
    case credentialRejected = "credential-rejected"
    case paused
    case actionFailure = "action-failure"
    case refreshFailure = "refresh-failure"
    case rateLimited = "rate-limited"
    case metadataUnavailable = "metadata-unavailable"

    static var selected: HarnessLovedFixture? {
        let raw = ProcessInfo.processInfo.environment["TRACKLOG_HARNESS_LOVED"] ?? ""
        return HarnessLovedFixture(rawValue: raw)
    }
}

enum HarnessLovedDemo {
    @MainActor
    static func link(on runtime: CaptureRuntime, droplet: TracklogDroplet) async {
        guard let fixture = HarnessLovedFixture.selected else {
            _ = try? await runtime.link(kind: .listenBrainz, credential: "demo-token")
            return
        }
        switch fixture {
        case .noConnection:
            break
        case .unsupported:
            guard let endpoint = ServiceEndpoint(normalizing: "https://compat.example") else {
                return
            }
            _ = try? await runtime.link(
                kind: .listenBrainz,
                credential: "demo-token",
                endpoint: endpoint,
            )
        case .metadataUnavailable:
            _ = try? await runtime.link(kind: .listenBrainz, credential: "demo-token")
        case .needsSignIn:
            guard let connection = try? await runtime.linkVerified(
                kind: .lastFM,
                credential: "demo-session",
                identity: ServiceIdentity(name: "listener"),
            ), let store = droplet.harnessStore
            else { return }
            var updated = connection
            updated.authState = .needsSignIn
            _ = try? await store.save(updated)
            await runtime.reloadConnections()
        case .paused:
            guard let connection = try? await runtime.linkVerified(
                kind: .lastFM,
                credential: "demo-session",
                identity: ServiceIdentity(name: "listener"),
            ), let id = connection.id
            else { return }
            try? await runtime.setConnectionEnabled(id: id, enabled: false)
        case .normal, .loading, .empty, .failed, .credentialRejected, .actionFailure,
             .refreshFailure, .rateLimited, .appCredentials, .longNames:
            _ = try? await runtime.link(kind: .lastFM, credential: "demo-session")
        }
    }

    /// Fixtures whose state needs a second interaction after the first read.
    @MainActor
    static func prepare(on droplet: TracklogDroplet) async {
        guard let fixture = HarnessLovedFixture.selected, let runtime = droplet.runtime else {
            return
        }
        switch fixture {
        case .actionFailure:
            await runtime.loved?.show()
            guard await waitForRows(runtime), let row = runtime.state.lovedState.rows.first else {
                return
            }
            await droplet.unloveLovedRow(row)
            _ = await waitUntil { runtime.state.lovedState.actionFailure != nil }
        case .refreshFailure:
            await runtime.loved?.show()
            guard await waitForRows(runtime) else { return }
            await runtime.loved?.refresh()
            _ = await waitUntil { runtime.state.lovedState.refreshFailure != nil }
        default:
            break
        }
    }

    @MainActor
    private static func waitForRows(_ runtime: CaptureRuntime) async -> Bool {
        await waitUntil {
            runtime.state.lovedState.phase == .ready
                && !runtime.state.lovedState.rows.isEmpty
        }
    }

    @MainActor
    private static func waitUntil(
        timeout: TimeInterval = 3,
        _ condition: @MainActor () -> Bool,
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                return false
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }
}

enum HarnessLovedFixtures {
    private static let refreshFailureReads = HarnessLovedReadCounter()

    // swiftlint:disable:next cyclomatic_complexity
    static func page(
        fixture: HarnessLovedFixture,
        connection: Connection,
        limit: Int,
    ) async throws -> LovedServicePage {
        switch fixture {
        case .loading:
            try? await Task.sleep(for: .seconds(30))
            return normalPage(connection: connection, limit: limit)
        case .empty:
            return LovedServicePage(rows: [], nextCursor: nil)
        case .failed:
            throw ServiceFailure.retryable
        case .appCredentials:
            throw ServiceFailure.appCredentialAuth(.missing)
        case .credentialRejected:
            throw ServiceFailure.auth
        case .rateLimited:
            throw ServiceFailure.rateLimited(retryAfter: 30)
        case .refreshFailure:
            guard refreshFailureReads.next() == 1 else {
                throw ServiceFailure.retryable
            }
            return normalPage(connection: connection, limit: limit)
        case .unsupported:
            throw LovedServiceError.unsupported(
                "This ListenBrainz-compatible server does not provide loved tracks.",
            )
        case .metadataUnavailable:
            return LovedServicePage(rows: [], omitted: 2, nextCursor: nil)
        case .normal, .longNames, .needsSignIn, .paused, .actionFailure, .noConnection:
            return normalPage(fixture: fixture, connection: connection, limit: limit)
        }
    }

    private static func normalPage(
        fixture: HarnessLovedFixture = .normal,
        connection: Connection,
        limit: Int,
    ) -> LovedServicePage {
        let titles: [String] = if fixture == .longNames {
            [
                "The Rise and Fall of the City of Mahagonny (Live at the Metropolitan Opera, Remastered Edition)",
                "A Very Long Track Name That Keeps Going Past the Available Width of the Row",
                "Another Lengthy Title for Truncation, Featuring Several Movements",
                "One More Long Title to Check the Ellipsis and the Spoken Label",
            ]
        } else {
            [
                "Example Track One",
                "Example Track Two",
                "Example Track Three",
                "Example Track Four",
                "Example Track Five",
                "Example Track Six",
                "Example Track Seven",
                "Example Track Eight",
            ]
        }
        let artist = fixture == .longNames
            ? "The Extremely Long-Named Artist Collective Featuring a Very Long Credit"
            : "Example Artist"
        let album = fixture == .longNames
            ? "Songs of the Deep and the Distant"
            : "Example Album"
        let rows = titles.enumerated().map { index, title in
            LovedRow(
                connectionID: connection.id,
                id: "harness:track:\(index)",
                title: title,
                artist: artist,
                album: album,
            )
        }
        return LovedServicePage(
            rows: Array(rows.prefix(max(1, limit))),
            nextCursor: nil,
        )
    }
}

/// A thread-safe counter for a fixture that changes its answer after the first
/// read.
final class HarnessLovedReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

// MARK: - Demo readers

extension HarnessDemoLastFMAdapter: LovedServiceReading {
    var firstCursor: LovedCursor {
        .page(1)
    }

    func loved(
        connection: Connection,
        credential _: String,
        cursor _: LovedCursor,
        limit: Int,
    ) async throws -> LovedServicePage {
        try await HarnessLovedFixtures.page(
            fixture: HarnessLovedFixture.selected ?? .normal,
            connection: connection,
            limit: limit,
        )
    }
}

extension HarnessDemoServiceAdapter: LovedServiceReading {
    var firstCursor: LovedCursor {
        .offset(0)
    }

    func loved(
        connection: Connection,
        credential _: String,
        cursor _: LovedCursor,
        limit: Int,
    ) async throws -> LovedServicePage {
        let fixture = HarnessLovedFixture.selected ?? .normal
        return try await HarnessLovedFixtures.page(
            fixture: fixture,
            connection: connection,
            limit: limit,
        )
    }
}
