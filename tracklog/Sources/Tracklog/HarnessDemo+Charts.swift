import Foundation
import TracklogCore

/// Harness-only chart scenarios. Each value selects both the SPA selection and
/// the scripted service answer; production never reads this.
enum HarnessChartFixture: String {
    case normal
    case loading
    case empty
    case notReady = "not-ready"
    case failed
    case failedSaved = "failed-saved"
    case longNames = "long-names"
    case noConnection = "no-connection"
    case local
    case libreFallback = "libre-fallback"
    case allTime = "all-time"

    static var selected: HarnessChartFixture? {
        let raw = ProcessInfo.processInfo.environment["TRACKLOG_HARNESS_CHARTS"] ?? ""
        return HarnessChartFixture(rawValue: raw)
    }

    var selection: ChartSelection {
        var selection = ChartSelection.initial(now: Date(), calendar: ChartCalendar.current)
        selection.period = self == .allTime ? .allTime : .week
        selection.type = .artists
        switch self {
        case .local:
            selection.source = .local
        case .libreFallback, .noConnection:
            selection.source = .service
        default:
            selection.source = .service
        }
        return selection
    }

    var linksLastFM: Bool {
        switch self {
        case .normal, .loading, .empty, .notReady, .failed, .failedSaved, .longNames, .allTime:
            true
        case .noConnection, .local, .libreFallback:
            false
        }
    }

    var linksLibreFM: Bool {
        self == .libreFallback
    }
}

enum HarnessChartFixtures {
    static func page(type: ChartType, fixture: HarnessChartFixture) -> ChartServicePage {
        switch fixture {
        case .empty:
            ChartServicePage(items: [], returnedRange: nil)
        case .loading:
            ChartServicePage(items: rows(type: type), returnedRange: nil)
        case .longNames:
            ChartServicePage(items: rows(type: type, long: true), returnedRange: nil)
        case .normal, .notReady, .failed, .failedSaved, .noConnection, .local, .libreFallback, .allTime:
            ChartServicePage(items: rows(type: type), returnedRange: nil)
        }
    }

    static func rows(type: ChartType, long: Bool = false) -> [ChartItem] {
        if long {
            switch type {
            case .artists:
                return [
                    row(1, "The Extremely Long-Named Artist Collective Featuring a Very Long Credit", "", 42, type),
                    row(2, "A Second Artist Whose Name Goes On Much Longer Than The Rail Can Show", "", 30, type),
                ]
            case .albums:
                return [
                    row(
                        1,
                        "An Album Title That Is Deliberately Long Enough To Truncate In The Native Row",
                        "The Extremely Long-Named Artist Collective",
                        42,
                        type,
                    ),
                ]
            case .tracks:
                return [
                    row(
                        1,
                        "A Track Title That Runs Far Past The Available Width So The Row Must Truncate",
                        "The Extremely Long-Named Artist Collective",
                        42,
                        type,
                    ),
                ]
            }
        }
        switch type {
        case .artists:
            return [
                row(1, "Blondie", "", 42, type),
                row(2, "Talking Heads", "", 35, type),
                row(3, "Fleetwood Mac", "", 28, type),
                row(4, "Massive Attack", "", 23, type),
                row(5, "New Order", "", 19, type),
                row(6, "Kate Bush", "", 16, type),
                row(7, "Björk", "", 12, type),
                row(8, "Portishead", "", 9, type),
            ]
        case .albums:
            return [
                row(1, "Parallel Lines", "Blondie", 30, type),
                row(2, "Remain in Light", "Talking Heads", 27, type),
                row(3, "Rumours", "Fleetwood Mac", 24, type),
                row(4, "Mezzanine", "Massive Attack", 20, type),
                row(5, "Power, Corruption & Lies", "New Order", 17, type),
                row(6, "Hounds of Love", "Kate Bush", 14, type),
                row(7, "Homogenic", "Björk", 11, type),
                row(8, "Dummy", "Portishead", 8, type),
            ]
        case .tracks:
            return [
                row(1, "Heart of Glass", "Blondie", 22, type),
                row(2, "Once in a Lifetime", "Talking Heads", 18, type),
                row(3, "Dreams", "Fleetwood Mac", 15, type),
                row(4, "Teardrop", "Massive Attack", 12, type),
                row(5, "Blue Monday", "New Order", 9, type),
                row(6, "Running Up That Hill", "Kate Bush", 7, type),
                row(7, "Jóga", "Björk", 5, type),
                row(8, "Glory Box", "Portishead", 3, type),
            ]
        }
    }

    static func accountTotal(fixture: HarnessChartFixture) async throws -> Int {
        switch fixture {
        case .loading:
            try? await Task.sleep(for: .seconds(30))
            return 12_345
        case .failed, .failedSaved:
            throw ServiceFailure.retryable
        case .notReady:
            throw ChartServiceError.notReady
        case .empty:
            return 0
        case .normal, .longNames, .noConnection, .local, .libreFallback, .allTime:
            return 12_345
        }
    }

    private static func row(
        _ rank: Int,
        _ title: String,
        _ subtitle: String,
        _ count: Int,
        _ type: ChartType,
    ) -> ChartItem {
        ChartItem(
            rank: rank,
            title: title,
            subtitle: subtitle,
            count: count,
            identityKey: "demo:\(type.rawValue):\(rank)",
            providerID: "demo-\(type.rawValue)-\(rank)",
            artworkHash: nil,
        )
    }
}

// MARK: - Chart clients

extension HarnessDemoLastFMAdapter: ChartServiceReading {
    func top(
        _ type: ChartType,
        period _: ChartPeriod,
        connection _: Connection,
        credential _: String,
        limit: Int,
    ) async throws -> ChartServicePage {
        let fixture = HarnessChartFixture.selected ?? .normal
        if fixture == .loading {
            try? await Task.sleep(for: .seconds(30))
        }
        switch fixture {
        case .loading, .normal, .longNames:
            let page = HarnessChartFixtures.page(type: type, fixture: fixture)
            return ChartServicePage(
                items: Array(page.items.prefix(limit)),
                returnedRange: nil,
            )
        case .empty:
            return ChartServicePage(items: [], returnedRange: nil)
        case .notReady:
            throw ChartServiceError.notReady
        case .failed, .failedSaved:
            throw ServiceFailure.retryable
        case .noConnection, .local, .libreFallback:
            return ChartServicePage(items: [], returnedRange: nil)
        case .allTime:
            return HarnessChartFixtures.page(type: type, fixture: .normal)
        }
    }

    func allTimeAccountTotal(
        connection _: Connection,
        credential _: String,
    ) async throws -> Int {
        try await HarnessChartFixtures.accountTotal(fixture: HarnessChartFixture.selected ?? .normal)
    }
}

extension HarnessDemoLastFMAdapter: FeedbackAdapter {
    func submitFeedback(
        _: FeedbackAction,
        track _: Track,
        reference _: RecordingReference?,
        connection _: Connection,
        credential _: String,
    ) async throws {
        // The harness has no network; the action still proves the composition.
    }
}

extension HarnessDemoServiceAdapter: ChartServiceReading {
    func top(
        _ type: ChartType,
        period _: ChartPeriod,
        connection _: Connection,
        credential _: String,
        limit: Int,
    ) async throws -> ChartServicePage {
        let fixture = HarnessChartFixture.selected ?? .normal
        if fixture == .loading {
            try? await Task.sleep(for: .seconds(30))
        }
        switch fixture {
        case .loading, .normal, .longNames:
            let page = HarnessChartFixtures.page(type: type, fixture: fixture)
            return ChartServicePage(items: Array(page.items.prefix(limit)), returnedRange: nil)
        case .empty:
            return ChartServicePage(items: [], returnedRange: nil)
        case .notReady:
            throw ChartServiceError.notReady
        case .failed, .failedSaved:
            throw ServiceFailure.retryable
        case .noConnection, .local, .libreFallback:
            return ChartServicePage(items: [], returnedRange: nil)
        case .allTime:
            return HarnessChartFixtures.page(type: type, fixture: .normal)
        }
    }

    func allTimeAccountTotal(
        connection _: Connection,
        credential _: String,
    ) async throws -> Int {
        try await HarnessChartFixtures.accountTotal(fixture: HarnessChartFixture.selected ?? .normal)
    }
}

/// A Libre.fm stand-in with no statistics adapter, so the named local
/// fallback can be exercised in the harness.
struct HarnessDemoLibreFMAdapter: ServiceAdapter {
    let kind = ServiceKind.libreFM
    let capabilities = ServiceCapabilities()

    func validate(_: String, endpoint _: ServiceEndpoint) async throws -> ServiceIdentity {
        ServiceIdentity(name: "libre-listener")
    }
}

// MARK: - Store chart half

extension HarnessDemoStore {
    func localChart(
        type: ChartType,
        window: LocalChartWindow,
        limit: Int,
    ) async throws -> LocalChartAggregate {
        var aggregator = LocalChartAggregator(type: type)
        for listen in listens.sorted(by: {
            if $0.startedAt != $1.startedAt {
                return $0.startedAt < $1.startedAt
            }
            return ($0.id ?? 0) < ($1.id ?? 0)
        }) {
            if let range = window.range, !range.contains(listen.startedAt) {
                continue
            }
            aggregator.add(
                title: listen.processed.title,
                artist: listen.processed.artist,
                album: listen.processed.album,
                albumArtist: listen.processed.albumArtist,
                artworkHash: listen.artworkHash,
            )
        }
        return aggregator.finish(limit: limit)
    }

    func chartCache(_ key: ChartCacheKey) async throws -> ChartCacheEntry? {
        if let entry = chartRows[key] {
            return entry
        }
        guard HarnessChartFixture.selected == .failedSaved,
              key.kind == .list,
              key.source == .service,
              let type = key.chartType
        else { return nil }
        let snapshot = ChartSnapshot(
            scopeKey: key.rawKey,
            type: type,
            period: key.period,
            items: HarnessChartFixtures.page(type: type, fixture: .normal).items,
            localTotal: nil,
            omittedCount: 0,
            returnedRange: nil,
            countUnit: .plays,
            savedAt: Date().addingTimeInterval(-2 * 60 * 60),
        )
        let payload = (try? JSONEncoder().encode(snapshot)) ?? Data()
        return ChartCacheEntry(savedAt: snapshot.savedAt, payload: payload)
    }

    func saveChartCache(_ entry: ChartCacheEntry, for key: ChartCacheKey) async throws {
        if key.source == .local {
            let shadowed = chartRows.keys.filter {
                $0.source == .local
                    && $0.kind == key.kind
                    && $0.chartType == key.chartType
                    && $0.period == key.period
                    && $0 != key
            }
            for old in shadowed {
                chartRows[old] = nil
            }
        }
        chartRows[key] = entry
    }

    func evictChartCaches(endpoint: String, account: String) async throws {
        let removed = chartRows.keys.filter {
            $0.source == .service && $0.endpoint == endpoint && $0.account == account
        }
        for key in removed {
            chartRows[key] = nil
        }
    }

    func pruneChartCaches() async throws {
        let stale = chartRows.keys.filter { $0.schemaVersion != ChartCacheSchema.version }
        for key in stale {
            chartRows[key] = nil
        }
    }

    func clearLocalCustomChartCaches() async throws {
        let custom = chartRows.keys.filter { $0.source == .local && $0.period == .custom }
        for key in custom {
            chartRows[key] = nil
        }
    }
}
