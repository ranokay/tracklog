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

    static var selected: HarnessLovedFixture? {
        let raw = ProcessInfo.processInfo.environment["TRACKLOG_HARNESS_LOVED"] ?? ""
        return HarnessLovedFixture(rawValue: raw)
    }
}

enum HarnessLovedDemo {
    @MainActor
    static func link(on runtime: CaptureRuntime) async {
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
        case .normal, .loading, .empty, .failed, .appCredentials, .longNames:
            _ = try? await runtime.link(kind: .lastFM, credential: "demo-session")
        }
    }
}

enum HarnessLovedFixtures {
    static let serviceName = "Last.fm"

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
        case .unsupported:
            throw LovedServiceError.unsupported(
                "This ListenBrainz-compatible server does not provide loved tracks.",
            )
        case .normal, .longNames:
            return normalPage(fixture: fixture, connection: connection, limit: limit)
        case .noConnection:
            return LovedServicePage(rows: [], nextCursor: nil)
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
        if fixture == .unsupported {
            throw LovedServiceError.unsupported(
                "This ListenBrainz-compatible server does not provide loved tracks.",
            )
        }
        return try await HarnessLovedFixtures.page(
            fixture: fixture == .noConnection ? .empty : fixture,
            connection: connection,
            limit: limit,
        )
    }
}
