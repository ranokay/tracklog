// swiftlint:disable file_length cyclomatic_complexity
import Foundation

/// The three ranked entities Core charts presents.
public enum ChartType: String, CaseIterable, Codable, Identifiable, Sendable {
    case artists
    case albums
    case tracks

    public var id: String {
        rawValue
    }

    public var displayName: String {
        switch self {
        case .artists: "Artists"
        case .albums: "Albums"
        case .tracks: "Tracks"
        }
    }

    public var singularName: String {
        switch self {
        case .artists: "artist"
        case .albums: "album"
        case .tracks: "track"
        }
    }

    /// The unit a row's count is spoken and drawn in. A service chart is a
    /// play count it returned; local history is a listen count this Mac stored.
    public var localCountUnit: ChartCountUnit {
        .listens
    }
}

public enum ChartCountUnit: String, Codable, Equatable, Sendable {
    case listens
    case plays

    public var singular: String {
        switch self {
        case .listens: "listen"
        case .plays: "play"
        }
    }

    public var plural: String {
        switch self {
        case .listens: "listens"
        case .plays: "plays"
        }
    }
}

/// The one period picker. Today and Custom are local-only; the four shared
/// periods map to each service's own native value.
public enum ChartPeriod: String, CaseIterable, Codable, Sendable {
    case today
    case week
    case month
    case year
    case allTime = "all-time"
    case custom

    public var displayName: String {
        switch self {
        case .today: "Today"
        case .week: "Week"
        case .month: "Month"
        case .year: "Year"
        case .allTime: "All time"
        case .custom: "Custom"
        }
    }

    public var isLocalOnly: Bool {
        self == .today || self == .custom
    }

    public var isSupportedByService: Bool {
        !isLocalOnly
    }

    /// Last.fm exposes rolling windows, not calendar ones.
    public var lastFMValue: String? {
        switch self {
        case .week: "7day"
        case .month: "1month"
        case .year: "12month"
        case .allTime: "overall"
        case .today, .custom: nil
        }
    }

    /// ListenBrainz's week/month/year are the previous completed calendar
    /// periods. Its own `this_*` ranges are deliberately not used.
    public var listenBrainzValue: String? {
        switch self {
        case .week: "week"
        case .month: "month"
        case .year: "year"
        case .allTime: "all_time"
        case .today, .custom: nil
        }
    }

    /// The honest label beneath a service list.
    public func serviceSemantics(for kind: ServiceKind) -> String? {
        switch kind {
        case .lastFM:
            switch self {
            case .week: "Rolling 7 days"
            case .month: "Rolling month"
            case .year: "Rolling 12 months"
            case .allTime: "All time"
            case .today, .custom: nil
            }
        case .listenBrainz:
            switch self {
            case .week: "Previous completed week"
            case .month: "Previous completed month"
            case .year: "Previous completed year"
            case .allTime: "All time"
            case .today, .custom: nil
            }
        case .libreFM:
            nil
        }
    }
}

public enum ChartSourceSelection: String, Codable, Equatable, Sendable {
    case service
    case local
}

/// A calendar date without a time zone. Custom ranges are selected dates, so
/// changing the Mac's time zone must keep 1 October as 1 October.
public struct ChartDate: Codable, Equatable, Hashable, Comparable, Sendable {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    public init(_ year: Int, _ month: Int, _ day: Int) {
        self.init(year: year, month: month, day: day)
    }

    public init(_ date: Date, calendar: Calendar) {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        year = components.year ?? 1970
        month = components.month ?? 1
        day = components.day ?? 1
    }

    public static func < (lhs: ChartDate, rhs: ChartDate) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    public func startDate(in calendar: Calendar) -> Date? {
        calendar.date(from: DateComponents(year: year, month: month, day: day))
    }

    public func formatted(in calendar: Calendar) -> String {
        guard let date = startDate(in: calendar) else {
            return "\(day)/\(month)/\(year)"
        }
        var style = Date.FormatStyle.dateTime.day().month(.abbreviated).year()
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }
}

/// The selection Charts keeps across launches. Chart type is part of the
/// selection; Custom dates only change when Settings saves them.
public struct ChartSelection: Codable, Equatable, Sendable {
    public var source: ChartSourceSelection
    public var period: ChartPeriod
    public var type: ChartType
    public var customStart: ChartDate
    public var customEnd: ChartDate

    public init(
        source: ChartSourceSelection = .service,
        period: ChartPeriod = .week,
        type: ChartType = .artists,
        customStart: ChartDate,
        customEnd: ChartDate,
    ) {
        self.source = source
        self.period = period
        self.type = type
        self.customStart = customStart
        self.customEnd = customEnd
    }

    public static var standard: ChartSelection {
        initial(now: Date(), calendar: ChartCalendar.current)
    }

    public static func initial(now: Date, calendar: Calendar) -> ChartSelection {
        let today = ChartDate(now, calendar: calendar)
        let weekAgo = calendar.date(byAdding: .day, value: -6, to: now) ?? now
        return ChartSelection(
            customStart: ChartDate(weekAgo, calendar: calendar),
            customEnd: today,
        )
    }
}

public enum ChartValidationError: Error, Equatable, LocalizedError {
    case reversedCustomRange

    public var errorDescription: String? {
        switch self {
        case .reversedCustomRange:
            "The end date must follow the start date."
        }
    }
}

public enum ChartLocalReason: Equatable, Sendable {
    case selected
    case unsupported(ServiceKind)
}

/// Where a chart read actually resolved after the current connection is
/// considered. A Libre.fm connection can only produce local history, and the
/// view names that fallback.
public enum ChartEffectiveSource: Equatable, Sendable {
    case local(reason: ChartLocalReason)
    case service(
        connectionID: Int64,
        kind: ServiceKind,
        endpoint: ServiceEndpoint,
        identity: String,
        displayName: String,
    )
    case none

    public var isLocal: Bool {
        if case .local = self {
            return true
        }
        return false
    }

    public var unsupportedService: ServiceKind? {
        guard case let .local(.unsupported(kind)) = self else { return nil }
        return kind
    }

    public var serviceKind: ServiceKind? {
        guard case let .service(_, kind, _, _, _) = self else { return nil }
        return kind
    }

    public var serviceLabel: String? {
        guard case let .service(_, kind, _, _, _) = self else { return nil }
        return kind.displayName
    }

    public var accountLabel: String? {
        guard case let .service(_, _, _, _, displayName) = self else { return nil }
        return displayName
    }
}

public struct ChartItem: Codable, Equatable, Identifiable, Sendable {
    public let rank: Int
    public let title: String
    public let subtitle: String
    public let count: Int
    /// The stable grouping key (local) or provider identity (service). It is
    /// never the stored metadata/feedback identity.
    public let identityKey: String
    public let providerID: String?
    public let artworkHash: String?

    public init(
        rank: Int,
        title: String,
        subtitle: String = "",
        count: Int,
        identityKey: String,
        providerID: String? = nil,
        artworkHash: String? = nil,
    ) {
        self.rank = rank
        self.title = title
        self.subtitle = subtitle
        self.count = count
        self.identityKey = identityKey
        self.providerID = providerID
        self.artworkHash = artworkHash
    }

    /// Rank keeps duplicate provider names distinct in a SwiftUI list.
    public var id: String {
        "\(rank)\u{1F}\(identityKey)"
    }
}

/// The span a service returned, and when it last computed it. Last.fm does
/// not expose these cutoffs, so its pages have no returned range.
public struct ChartReturnedRange: Codable, Equatable, Sendable {
    public let start: Date
    public let end: Date
    public let lastUpdated: Date?

    public init(start: Date, end: Date, lastUpdated: Date? = nil) {
        self.start = start
        self.end = end
        self.lastUpdated = lastUpdated
    }
}

/// One successful ranked result. The scope key is checked again when a cache
/// row is decoded, so a row can never be displayed as another selection.
public struct ChartSnapshot: Codable, Equatable, Sendable {
    public let scopeKey: String
    public let type: ChartType
    public let period: ChartPeriod
    public let items: [ChartItem]
    /// Local exact total across every listen in the resolved window.
    public let localTotal: Int?
    public let omittedCount: Int
    public let returnedRange: ChartReturnedRange?
    public let countUnit: ChartCountUnit
    public var savedAt: Date

    public init(
        scopeKey: String,
        type: ChartType,
        period: ChartPeriod,
        items: [ChartItem],
        localTotal: Int?,
        omittedCount: Int,
        returnedRange: ChartReturnedRange?,
        countUnit: ChartCountUnit,
        savedAt: Date,
    ) {
        self.scopeKey = scopeKey
        self.type = type
        self.period = period
        self.items = items
        self.localTotal = localTotal
        self.omittedCount = omittedCount
        self.returnedRange = returnedRange
        self.countUnit = countUnit
        self.savedAt = savedAt
    }
}

/// The separately timestamped all-time account count. It is not a sum of the
/// ranked rows and is never used for a bounded period.
public struct ChartAccountTotal: Codable, Equatable, Sendable {
    public let value: Int
    public let serviceName: String
    public var savedAt: Date

    public init(value: Int, serviceName: String, savedAt: Date) {
        self.value = value
        self.serviceName = serviceName
        self.savedAt = savedAt
    }
}

public enum ChartTotalsUnavailable: Equatable, Sendable {
    case rangeTotals
    case accountTotal(ChartFailure)
}

public enum ChartTotalsDisplay: Equatable, Sendable {
    case none
    case loading
    case local(Int)
    case account(ChartAccountTotal)
    case unavailable(ChartTotalsUnavailable)
}

public enum ChartFailure: Equatable, Sendable {
    case offline
    case needsSignIn
    case appCredentials
    case rateLimited(retryAfter: TimeInterval?)
    case service(String?)
    case localRead
    case invalidRange
    case notReady
}

public enum ChartPhase: Equatable, Sendable {
    case idle
    case loading
    case ready
    case empty
    case noConnection
    case notReady
    case failed(ChartFailure)
    /// Every listen in the range is present but lacks the fields this list
    /// groups on. The exact range total still counts them.
    case noMetadata(omitted: Int)
}

/// The one published charts state. The view never derives a row or a total
/// from another selection.
public struct ChartViewState: Equatable, Sendable {
    public var selection: ChartSelection
    public var phase: ChartPhase
    public var snapshot: ChartSnapshot?
    public var totals: ChartTotalsDisplay
    public var totalFailure: ChartFailure?
    public var refreshFailure: ChartFailure?
    public var isRefreshing: Bool
    public var effectiveSource: ChartEffectiveSource
    public var periodDetail: String?

    public init(selection: ChartSelection) {
        self.selection = selection
        phase = .idle
        snapshot = nil
        totals = .none
        totalFailure = nil
        refreshFailure = nil
        isRefreshing = false
        effectiveSource = .none
        periodDetail = nil
    }
}

public enum TakeoverSection: String, Equatable, Sendable {
    case history
    case charts
}

public enum ChartLimits {
    public static let topEntityLimit = 50
}

public enum ChartFreshness {
    public static let interval: TimeInterval = 15 * 60
}

// swiftlint:enable file_length cyclomatic_complexity
