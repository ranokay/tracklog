// swiftlint:disable cyclomatic_complexity
import Foundation

/// The one calendar contract behind local chart windows: Gregorian, the Mac's
/// current time zone, Monday-first weeks.
public enum ChartCalendar {
    public static var current: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        calendar.locale = .current
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }
}

/// A resolved local window. `range` is nil only for All time.
public struct LocalChartWindow: Equatable, Sendable {
    public let period: ChartPeriod
    public let range: Range<Date>?
    public let timeZoneID: String

    public init(period: ChartPeriod, range: Range<Date>?, timeZoneID: String) {
        self.period = period
        self.range = range
        self.timeZoneID = timeZoneID
    }
}

public enum ChartWindows {
    /// Resolves the half-open local window. Today, Week, Month, Year and All
    /// time ignore the stored Custom dates; Custom validates and uses them.
    public static func resolve(
        selection: ChartSelection,
        now: Date,
        calendar: Calendar,
    ) throws -> LocalChartWindow {
        let timeZoneID = calendar.timeZone.identifier
        switch selection.period {
        case .allTime:
            return LocalChartWindow(period: .allTime, range: nil, timeZoneID: timeZoneID)
        case .today:
            guard let day = calendar.dateInterval(of: .day, for: now) else {
                throw ChartValidationError.reversedCustomRange
            }
            return LocalChartWindow(period: .today, range: day.start ..< day.end, timeZoneID: timeZoneID)
        case .week:
            guard let week = calendar.dateInterval(of: .weekOfYear, for: now) else {
                throw ChartValidationError.reversedCustomRange
            }
            return LocalChartWindow(period: .week, range: week.start ..< week.end, timeZoneID: timeZoneID)
        case .month:
            guard let month = calendar.dateInterval(of: .month, for: now) else {
                throw ChartValidationError.reversedCustomRange
            }
            return LocalChartWindow(period: .month, range: month.start ..< month.end, timeZoneID: timeZoneID)
        case .year:
            guard let year = calendar.dateInterval(of: .year, for: now) else {
                throw ChartValidationError.reversedCustomRange
            }
            return LocalChartWindow(period: .year, range: year.start ..< year.end, timeZoneID: timeZoneID)
        case .custom:
            guard selection.customEnd >= selection.customStart,
                  let start = selection.customStart.startDate(in: calendar),
                  let endDay = selection.customEnd.startDate(in: calendar),
                  let endExclusive = calendar.date(byAdding: .day, value: 1, to: endDay)
            else {
                throw ChartValidationError.reversedCustomRange
            }
            let startOfStart = calendar.startOfDay(for: start)
            let startOfEnd = calendar.startOfDay(for: endDay)
            guard startOfEnd >= startOfStart else {
                throw ChartValidationError.reversedCustomRange
            }
            return LocalChartWindow(
                period: .custom,
                range: startOfStart ..< endExclusive,
                timeZoneID: timeZoneID,
            )
        }
    }

    /// A short range caption for the rail and the list heading.
    public static func caption(selection: ChartSelection, calendar: Calendar) -> String {
        switch selection.period {
        case .today: "Today"
        case .week: "This week"
        case .month: "This month"
        case .year: "This year"
        case .allTime: "All time"
        case .custom:
            "\(selection.customStart.formatted(in: calendar)) – \(selection.customEnd.formatted(in: calendar))"
        }
    }
}

// swiftlint:enable cyclomatic_complexity
