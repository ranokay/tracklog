import Foundation

public enum ChartCacheKind: String, Codable, Equatable, Sendable {
    case list
    case total
}

public enum ChartCacheSchema {
    /// Bump when a stored chart payload or its scope meaning changes. Rows
    /// from another version are pruned rather than decoded.
    public static let version = 1
}

/// The full identity of one persisted chart result. Every component is part
/// of the key: a cached row can never answer another account, source, type,
/// period, time zone or resolved window.
public struct ChartCacheKey: Hashable, Sendable {
    public let kind: ChartCacheKind
    public let source: ChartSourceSelection
    public let serviceKind: ServiceKind?
    public let endpoint: String
    public let account: String
    public let chartType: ChartType?
    public let period: ChartPeriod
    public let timeZoneID: String
    public let windowStart: Date?
    public let windowEnd: Date?
    public let schemaVersion: Int

    public init(
        kind: ChartCacheKind,
        source: ChartSourceSelection,
        serviceKind: ServiceKind? = nil,
        endpoint: String = "",
        account: String = "",
        chartType: ChartType? = nil,
        period: ChartPeriod,
        timeZoneID: String = "",
        windowStart: Date? = nil,
        windowEnd: Date? = nil,
        schemaVersion: Int = ChartCacheSchema.version,
    ) {
        self.kind = kind
        self.source = source
        self.serviceKind = serviceKind
        self.endpoint = endpoint
        self.account = account
        self.chartType = chartType
        self.period = period
        self.timeZoneID = timeZoneID
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.schemaVersion = schemaVersion
    }

    /// A collision-free enough durable key. The unit separator cannot appear
    /// in a service identity or a URL; the stored columns remain the readable
    /// scope for eviction queries.
    public var rawKey: String {
        [
            kind.rawValue,
            source.rawValue,
            serviceKind?.rawValue ?? "",
            endpoint,
            account,
            chartType?.rawValue ?? "",
            period.rawValue,
            timeZoneID,
            windowStart.map { String($0.timeIntervalSince1970) } ?? "",
            windowEnd.map { String($0.timeIntervalSince1970) } ?? "",
            String(schemaVersion),
        ].joined(separator: "\u{1F}")
    }
}

public struct ChartCacheEntry: Equatable, Sendable {
    public let savedAt: Date
    public let payload: Data

    public init(savedAt: Date, payload: Data) {
        self.savedAt = savedAt
        self.payload = payload
    }
}

/// The durable chart cache. SQLite is the production store; the harness keeps
/// the same small surface in memory.
public protocol ChartCacheStore: Sendable {
    func chartCache(_ key: ChartCacheKey) async throws -> ChartCacheEntry?
    func saveChartCache(_ entry: ChartCacheEntry, for key: ChartCacheKey) async throws
    func evictChartCaches(endpoint: String, account: String) async throws
    func pruneChartCaches() async throws
    func clearLocalCustomChartCaches() async throws
}

/// One grouped local result. The total is exactly every stored listen in the
/// window, including rows omitted from the ranked list.
public struct LocalChartAggregate: Equatable, Sendable {
    public let items: [ChartItem]
    public let total: Int
    public let omittedCount: Int

    public init(items: [ChartItem], total: Int, omittedCount: Int) {
        self.items = items
        self.total = total
        self.omittedCount = omittedCount
    }
}

public protocol LocalChartReading: Sendable {
    func localChart(
        type: ChartType,
        window: LocalChartWindow,
        limit: Int,
    ) async throws -> LocalChartAggregate
}

/// The SQLite store's chart half: exact local grouping plus the bounded cache.
public protocol ChartStore: ChartCacheStore, LocalChartReading {}
